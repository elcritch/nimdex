## Minimal LSP 3.18 session handling for Nimdex.

import std/[json, syncio]

import sigils
import sigils/rpcs/jsonrpc
import sigils/rpcs/json/jrStdio as jrStdio

import ./language

const
  LspServerNotInitialized* = -32002'i32 ## LSP error for pre-initialization requests.
  LspExitSuccess* = 0 ## Exit status after a valid shutdown and exit sequence.
  LspExitFailure* = 1 ## Exit status when the client exits without shutdown.

type
  LspSessionState* = enum ## Lifecycle states of an LSP server session.
    lssCreated ## No initialize request has been accepted.
    lssInitializing ## Initialize completed; awaiting initialized.
    lssRunning ## The server may process document and language messages.
    lssShuttingDown ## Shutdown completed; awaiting exit.
    lssExited ## The client requested process termination.

  LspServer* = ref object of DynamicAgent ## A Nimdex LSP session and its worker bridge.
    adapter: JsonRpcAdapter
    language: LanguageRuntime
    home: SigilThreadPtr
    state: LspSessionState
    exitRequested: bool
    exitStatus: int

let
  initializeSelector = selector[JsonNode, JsonNode]("initialize")
  initializedSelector = selector[JsonNode, JsonNode]("initialized")
  shutdownSelector = selector[JsonNode, JsonNode]("shutdown")
  exitSelector = selector[JsonNode, JsonNode]("exit")
  didOpenSelector = selector[JsonNode, JsonNode]("textDocument/didOpen")
  didChangeSelector = selector[JsonNode, JsonNode]("textDocument/didChange")
  didCloseSelector = selector[JsonNode, JsonNode]("textDocument/didClose")
  hoverSelector = selector[JsonNode, JsonNode]("textDocument/hover")

proc raiseLspError(code: int32, message: string) {.noreturn.} =
  let error = newException(RpcRouteError, message)
  error.code = code
  raise error

proc requireObject(node: JsonNode, description: string): JsonNode =
  if node.isNil or node.kind != JObject:
    raiseLspError(RpcInvalidParams, description & " must be an object")
  node

proc requireMember(node: JsonNode, name, description: string): JsonNode =
  if not node.hasKey(name):
    raiseLspError(RpcInvalidParams, description & " is missing " & name)
  let member = node[name]
  if member.isNil:
    raiseLspError(RpcInvalidParams, description & " has a null " & name)
  member

proc requireString(node: JsonNode, name, description: string): string =
  let member = requireMember(node, name, description)
  if member.kind != JString:
    raiseLspError(RpcInvalidParams, description & "." & name & " must be a string")
  member.getStr()

proc requireInt(node: JsonNode, name, description: string): int =
  let member = requireMember(node, name, description)
  if member.kind != JInt:
    raiseLspError(RpcInvalidParams, description & "." & name & " must be an integer")
  member.getInt()

proc parseOpenRequest(params: JsonNode): LanguageRequest =
  let document = requireObject(
    requireMember(
      requireObject(params, "didOpen params"), "textDocument", "didOpen params"
    ),
    "didOpen textDocument",
  )
  result = LanguageRequest(
    kind: lrkOpen,
    uri: requireString(document, "uri", "didOpen textDocument"),
    version: requireInt(document, "version", "didOpen textDocument"),
    text: requireString(document, "text", "didOpen textDocument"),
  )

proc parseChangeRequest(params: JsonNode): LanguageRequest =
  let root = requireObject(params, "didChange params")
  let document = requireObject(
    requireMember(root, "textDocument", "didChange params"), "didChange textDocument"
  )
  let changes = requireMember(root, "contentChanges", "didChange params")
  if changes.kind != JArray or changes.len == 0:
    raiseLspError(
      RpcInvalidParams, "didChange params.contentChanges must be a non-empty array"
    )

  var text = ""
  for change in changes:
    let fullChange = requireObject(change, "didChange content change")
    text = requireString(fullChange, "text", "didChange content change")

  result = LanguageRequest(
    kind: lrkChange,
    uri: requireString(document, "uri", "didChange textDocument"),
    version: requireInt(document, "version", "didChange textDocument"),
    text: text,
  )

proc parseCloseRequest(params: JsonNode): LanguageRequest =
  let root = requireObject(params, "didClose params")
  let document = requireObject(
    requireMember(root, "textDocument", "didClose params"), "didClose textDocument"
  )
  LanguageRequest(
    kind: lrkClose, uri: requireString(document, "uri", "didClose textDocument")
  )

proc parseHoverRequest(params: JsonNode): LanguageRequest =
  let root = requireObject(params, "hover params")
  let document = requireObject(
    requireMember(root, "textDocument", "hover params"), "hover textDocument"
  )
  let position =
    requireObject(requireMember(root, "position", "hover params"), "hover position")
  result = LanguageRequest(
    kind: lrkHover,
    uri: requireString(document, "uri", "hover textDocument"),
    line: requireInt(position, "line", "hover position"),
    character: requireInt(position, "character", "hover position"),
  )

proc requireRunning(server: LspServer) =
  case server.state
  of lssRunning:
    discard
  of lssCreated, lssInitializing:
    raiseLspError(LspServerNotInitialized, "server is not initialized")
  of lssShuttingDown, lssExited:
    raiseLspError(RpcInvalidRequest, "server is shutting down")

proc requireLanguageSuccess(response: LanguageResponse) =
  if not response.ok:
    raiseLspError(RpcInternalError, response.error)

proc initializeLsp(server: LspServer, params: JsonNode): JsonNode =
  if server.state != lssCreated:
    raiseLspError(RpcInvalidRequest, "server has already been initialized")
  discard requireObject(params, "initialize params")

  server.state = lssInitializing
  result = newJObject()
  let capabilities = newJObject()
  let textDocumentSync = newJObject()
  textDocumentSync["openClose"] = %true
  textDocumentSync["change"] = %1
  capabilities["textDocumentSync"] = textDocumentSync
  capabilities["hoverProvider"] = %true
  result["capabilities"] = capabilities

  let serverInfo = newJObject()
  serverInfo["name"] = %"nimdex"
  serverInfo["version"] = %"0.1.0"
  result["serverInfo"] = serverInfo

proc initializedLsp(server: LspServer, params: JsonNode): JsonNode =
  discard params
  if server.state != lssInitializing:
    if server.state in {lssCreated}:
      raiseLspError(LspServerNotInitialized, "server is not initialized")
    raiseLspError(RpcInvalidRequest, "unexpected initialized notification")
  server.state = lssRunning
  newJNull()

proc shutdownLsp(server: LspServer, params: JsonNode): JsonNode =
  discard params
  server.requireRunning()
  server.state = lssShuttingDown
  newJNull()

proc exitLsp(server: LspServer, params: JsonNode): JsonNode =
  discard params
  if not server.exitRequested:
    server.exitRequested = true
    server.exitStatus =
      if server.state == lssShuttingDown: LspExitSuccess else: LspExitFailure
    server.state = lssExited
  newJNull()

proc didOpenLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let response = server.language.request(parseOpenRequest(params))
  requireLanguageSuccess(response)
  newJNull()

proc didChangeLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let response = server.language.request(parseChangeRequest(params))
  requireLanguageSuccess(response)
  newJNull()

proc didCloseLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let response = server.language.request(parseCloseRequest(params))
  requireLanguageSuccess(response)
  newJNull()

proc hoverLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let response = server.language.request(parseHoverRequest(params))
  requireLanguageSuccess(response)
  if not response.found:
    return newJNull()

  let contents = newJObject()
  contents["kind"] = %"markdown"
  contents["value"] =
    %(
      "Nimdex shim\n\nURI: `" & response.uri & "`\nVersion: " & $response.version &
      "\n\n" & response.preview
    )
  result = newJObject()
  result["contents"] = contents

proc registerLspRoutes(server: LspServer) =
  discard server.addMethod(initializeSelector, toDynamicMethod(initializeLsp))
  discard server.addMethod(initializedSelector, toDynamicMethod(initializedLsp))
  discard server.addMethod(shutdownSelector, toDynamicMethod(shutdownLsp))
  discard server.addMethod(exitSelector, toDynamicMethod(exitLsp))
  discard server.addMethod(didOpenSelector, toDynamicMethod(didOpenLsp))
  discard server.addMethod(didChangeSelector, toDynamicMethod(didChangeLsp))
  discard server.addMethod(didCloseSelector, toDynamicMethod(didCloseLsp))
  discard server.addMethod(hoverSelector, toDynamicMethod(hoverLsp))

  server.adapter.registerSelectorMethod("initialize", server, initializeSelector)
  server.adapter.registerSelectorMethod("initialized", server, initializedSelector)
  server.adapter.registerSelectorMethod("shutdown", server, shutdownSelector)
  server.adapter.registerSelectorMethod("exit", server, exitSelector)
  server.adapter.registerSelectorMethod("textDocument/didOpen", server, didOpenSelector)
  server.adapter.registerSelectorMethod(
    "textDocument/didChange", server, didChangeSelector
  )
  server.adapter.registerSelectorMethod(
    "textDocument/didClose", server, didCloseSelector
  )
  server.adapter.registerSelectorMethod("textDocument/hover", server, hoverSelector)

proc newNimdexLspServer*(workers = 1): LspServer =
  ## Create an LSP server with shimmed language components on a worker pool.
  startLocalThreadDefault()
  result = LspServer(
    adapter: newJsonRpcAdapter(),
    language: newLanguageRuntime(workers),
    home: getCurrentSigilThread(),
    state: lssCreated,
    exitStatus: LspExitSuccess,
  )
  result.registerLspRoutes()

proc jsonRpcAdapter*(server: LspServer): JsonRpcAdapter =
  ## Return the transport-independent JSON-RPC adapter for this server.
  if server.isNil:
    return nil
  server.adapter

proc isExitRequested*(server: LspServer): bool =
  ## Return whether the client has requested process termination.
  not server.isNil and server.exitRequested

proc exitStatus*(server: LspServer): int =
  ## Return the process status selected by the LSP exit notification.
  if server.isNil:
    return LspExitFailure
  server.exitStatus

proc close*(server: LspServer) =
  ## Stop the language worker pool owned by the server.
  if not server.isNil:
    server.language.close()

proc runNimdexLspStdio*(input: File = stdin, output: File = stdout, workers = 1): int =
  ## Serve LSP Content-Length messages until EOF or an ``exit`` notification.
  let server = newNimdexLspServer(workers)
  let dispatcher = newJsonRpcDispatcher(server.adapter)
  let io = jrStdio.newJsonRpcStdioIo(input, output)
  dispatcher.connectJsonRpc(io)
  emit dispatcher.jsonRpcStartRequested()

  try:
    while io.pollJsonRpcStdio():
      discard server.home.pollAll(NonBlocking)
      if server.isExitRequested():
        io.stopIo()
        break
  finally:
    server.close()

  server.exitStatus()
