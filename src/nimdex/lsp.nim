## Minimal LSP 3.18 session handling for Nimdex.

import std/[json, os, strutils, syncio]

import sigils
import sigils/rpcs/jsonrpc
import sigils/rpcs/json/jrStdio as jrStdio

import ./bifindex
import ./documents
import ./language
import ./workspace

const
  LspServerNotInitialized* = -32002'i32 ## LSP error for pre-initialization requests.
  LspAnalysisUnavailable* = -32001'i32 ## No compiler-backed snapshot is installed.
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
    workspace: Workspace
    artifactRoots: seq[string]
    semanticCapabilities: bool
    positionEncoding: PositionEncoding
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
  documentSymbolSelector = selector[JsonNode, JsonNode]("textDocument/documentSymbol")
  workspaceSymbolSelector = selector[JsonNode, JsonNode]("workspace/symbol")
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

proc stringArray(node: JsonNode, name, description: string): seq[string] =
  if node.isNil or node.kind != JObject or not node.hasKey(name):
    return
  let member = node[name]
  if member.kind != JArray:
    raiseLspError(RpcInvalidParams, description & "." & name & " must be an array")
  for value in member:
    if value.kind != JString:
      raiseLspError(
        RpcInvalidParams, description & "." & name & " must contain strings"
      )
    result.add(value.getStr())

proc rootUriFromInitialize(params: JsonNode): string =
  if params.hasKey("rootUri") and params["rootUri"].kind == JString:
    return params["rootUri"].getStr()
  if params.hasKey("rootPath") and params["rootPath"].kind == JString:
    return params["rootPath"].getStr()
  if params.hasKey("workspaceFolders") and params["workspaceFolders"].kind == JArray:
    for folder in params["workspaceFolders"]:
      if folder.kind != JObject or not folder.hasKey("uri"):
        continue
      if folder["uri"].kind == JString:
        return folder["uri"].getStr()

proc artifactRootsFromInitialize(params: JsonNode): seq[string] =
  if not params.hasKey("initializationOptions"):
    return
  let options = params["initializationOptions"]
  if options.kind != JObject:
    return
  result = stringArray(options, "artifactRoots", "initialize initializationOptions")

proc resolveArtifactRoots(rootUri: string, roots: openArray[string]): seq[string] =
  let rootPath = pathFromDocumentUri(rootUri)
  for root in roots:
    if root.len == 0:
      continue
    result.add(
      if rootPath.len > 0 and not isAbsolute(root):
        rootPath / root
      else:
        root
    )

proc parseOpenRequest(
    params: JsonNode, positionEncoding: PositionEncoding
): LanguageRequest =
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
    positionEncoding: positionEncoding,
  )

proc parseChangeRequest(
    params: JsonNode, positionEncoding: PositionEncoding
): LanguageRequest =
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
    if fullChange.hasKey("range") or fullChange.hasKey("rangeLength"):
      raiseLspError(
        RpcInvalidParams,
        "ranged document changes are not supported; send full document text",
      )
    text = requireString(fullChange, "text", "didChange content change")

  result = LanguageRequest(
    kind: lrkChange,
    uri: requireString(document, "uri", "didChange textDocument"),
    version: requireInt(document, "version", "didChange textDocument"),
    text: text,
    positionEncoding: positionEncoding,
  )

proc parseCloseRequest(params: JsonNode): LanguageRequest =
  let root = requireObject(params, "didClose params")
  let document = requireObject(
    requireMember(root, "textDocument", "didClose params"), "didClose textDocument"
  )
  LanguageRequest(
    kind: lrkClose, uri: requireString(document, "uri", "didClose textDocument")
  )

proc parseHoverRequest(
    params: JsonNode, positionEncoding: PositionEncoding
): LanguageRequest =
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
    positionEncoding: positionEncoding,
  )

proc parseDocumentSymbolsRequest(
    params: JsonNode, positionEncoding: PositionEncoding
): LanguageRequest =
  let root = requireObject(params, "documentSymbol params")
  let document = requireObject(
    requireMember(root, "textDocument", "documentSymbol params"),
    "documentSymbol textDocument",
  )
  LanguageRequest(
    kind: lrkDocumentSymbols,
    uri: requireString(document, "uri", "documentSymbol textDocument"),
    positionEncoding: positionEncoding,
  )

proc parseWorkspaceSymbolsRequest(
    params: JsonNode, positionEncoding: PositionEncoding
): LanguageRequest =
  let root = requireObject(params, "workspace/symbol params")
  LanguageRequest(
    kind: lrkWorkspaceSymbols,
    query: requireString(root, "query", "workspace/symbol params"),
    positionEncoding: positionEncoding,
  )

proc positionEncodingName(encoding: PositionEncoding): string =
  case encoding
  of peUtf8: "utf-8"
  of peUtf16: "utf-16"
  of peUtf32: "utf-32"

proc negotiatePositionEncoding(params: JsonNode): PositionEncoding =
  ## LSP defaults to UTF-16 when the client does not advertise a preference.
  if params.kind != JObject or not params.hasKey("capabilities"):
    return peUtf16
  let capabilities = params["capabilities"]
  if capabilities.kind != JObject or not capabilities.hasKey("general"):
    return peUtf16
  let general = capabilities["general"]
  if general.kind != JObject or not general.hasKey("positionEncodings"):
    return peUtf16
  let encodings = general["positionEncodings"]
  if encodings.kind != JArray:
    raiseLspError(
      RpcInvalidParams,
      "initialize capabilities.general.positionEncodings must be an array",
    )
  for value in encodings:
    if value.kind != JString:
      continue
    case value.getStr().toLowerAscii()
    of "utf-8":
      return peUtf8
    of "utf-16":
      return peUtf16
    of "utf-32":
      return peUtf32
    else:
      discard
  peUtf16

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
    let code =
      if response.error.startsWith("analysis unavailable"):
        LspAnalysisUnavailable
      else:
        RpcInternalError
    raiseLspError(code, response.error)

proc installSemanticIndex(server: LspServer) =
  if not server.semanticCapabilities:
    return
  try:
    var snapshot = buildBifIndex(server.workspace, server.artifactRoots)
    server.language.installIndex(snapshot)
  except CatchableError:
    ## Capability advertisement remains useful when a refresh cannot be
    ## completed, but the language actor will correctly return no results
    ## until a complete snapshot is installed.
    discard

proc lspPosition(position: TextPosition): JsonNode =
  result = newJObject()
  result["line"] = %position.line
  result["character"] = %position.character

proc lspRange(symbol: LanguageSymbol): JsonNode =
  result = newJObject()
  result["start"] = lspPosition(symbol.start)
  result["end"] = lspPosition(symbol.finish)

proc lspSymbolKind(symbol: SymbolInfo): int =
  let kind = symbol.kind.toLowerAscii()
  if kind.contains("namespace"):
    return 3
  if kind.contains("module"):
    return 2
  if kind.contains("method"):
    return 6
  if kind.contains("field"):
    return 8
  if kind.contains("constructor"):
    return 9
  if kind.contains("enum"):
    return 10
  if kind.contains("interface"):
    return 11
  if kind.contains("proc") or kind.contains("func") or kind.contains("routine"):
    return 12
  if kind.contains("constant"):
    return 14
  if kind.contains("type") or kind.contains("class") or kind.contains("object"):
    return 5
  ## Binny's generic declaration tag has no narrower LSP equivalent.
  13

proc lspSymbolInformation(symbol: LanguageSymbol): JsonNode =
  result = newJObject()
  result["name"] = %symbol.symbol.name
  result["kind"] = %symbol.symbol.lspSymbolKind()
  let location = newJObject()
  location["uri"] = %symbol.symbol.location.uri
  location["range"] = symbol.lspRange()
  result["location"] = location

proc initializeLsp(server: LspServer, params: JsonNode): JsonNode =
  if server.state != lssCreated:
    raiseLspError(RpcInvalidRequest, "server has already been initialized")
  let initializeParams = requireObject(params, "initialize params")
  server.positionEncoding = negotiatePositionEncoding(params)
  let configuredRoots =
    if server.artifactRoots.len > 0:
      server.artifactRoots
    else:
      artifactRootsFromInitialize(initializeParams)
  let rootUri = rootUriFromInitialize(initializeParams)
  server.workspace = initWorkspace(
    rootUri, artifactRoots = resolveArtifactRoots(rootUri, configuredRoots)
  )
  server.artifactRoots = server.workspace.artifactRoots
  server.semanticCapabilities = server.artifactRoots.len > 0

  server.state = lssInitializing
  result = newJObject()
  let capabilities = newJObject()
  let textDocumentSync = newJObject()
  textDocumentSync["openClose"] = %true
  textDocumentSync["change"] = %1
  capabilities["textDocumentSync"] = textDocumentSync
  capabilities["positionEncoding"] = %server.positionEncoding.positionEncodingName()
  if server.semanticCapabilities:
    capabilities["documentSymbolProvider"] = %true
    capabilities["workspaceSymbolProvider"] = %true
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
  server.installSemanticIndex()
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
  let response =
    server.language.request(parseOpenRequest(params, server.positionEncoding))
  requireLanguageSuccess(response)
  newJNull()

proc didChangeLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let response =
    server.language.request(parseChangeRequest(params, server.positionEncoding))
  requireLanguageSuccess(response)
  newJNull()

proc didCloseLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let response = server.language.request(parseCloseRequest(params))
  requireLanguageSuccess(response)
  newJNull()

proc documentSymbolsLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let response = server.language.request(
    parseDocumentSymbolsRequest(params, server.positionEncoding)
  )
  requireLanguageSuccess(response)
  result = newJArray()
  for symbol in response.symbols:
    result.add(symbol.lspSymbolInformation())

proc workspaceSymbolsLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let response = server.language.request(
    parseWorkspaceSymbolsRequest(params, server.positionEncoding)
  )
  requireLanguageSuccess(response)
  result = newJArray()
  for symbol in response.symbols:
    result.add(symbol.lspSymbolInformation())

proc hoverLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let response =
    server.language.request(parseHoverRequest(params, server.positionEncoding))
  requireLanguageSuccess(response)
  if not response.found:
    return newJNull()

  let contents = newJObject()
  contents["kind"] = %"markdown"
  contents["value"] = %response.preview
  result = newJObject()
  result["contents"] = contents
  result["range"] = response.symbols[0].lspRange()

proc registerLspRoutes(server: LspServer) =
  discard server.addMethod(initializeSelector, toDynamicMethod(initializeLsp))
  discard server.addMethod(initializedSelector, toDynamicMethod(initializedLsp))
  discard server.addMethod(shutdownSelector, toDynamicMethod(shutdownLsp))
  discard server.addMethod(exitSelector, toDynamicMethod(exitLsp))
  discard server.addMethod(didOpenSelector, toDynamicMethod(didOpenLsp))
  discard server.addMethod(didChangeSelector, toDynamicMethod(didChangeLsp))
  discard server.addMethod(didCloseSelector, toDynamicMethod(didCloseLsp))
  discard server.addMethod(documentSymbolSelector, toDynamicMethod(documentSymbolsLsp))
  discard
    server.addMethod(workspaceSymbolSelector, toDynamicMethod(workspaceSymbolsLsp))
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
  server.adapter.registerSelectorMethod(
    "textDocument/documentSymbol", server, documentSymbolSelector
  )
  server.adapter.registerSelectorMethod(
    "workspace/symbol", server, workspaceSymbolSelector
  )
  server.adapter.registerSelectorMethod("textDocument/hover", server, hoverSelector)

proc newNimdexLspServer*(workers = 1, artifactRoots: seq[string] = @[]): LspServer =
  ## Create an LSP server with worker-owned document state.
  startLocalThreadDefault()
  result = LspServer(
    adapter: newJsonRpcAdapter(),
    language: newLanguageRuntime(workers),
    home: getCurrentSigilThread(),
    artifactRoots: artifactRoots,
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

proc runNimdexLspStdio*(
    input: File = stdin,
    output: File = stdout,
    workers = 1,
    artifactRoots: seq[string] = @[],
): int =
  ## Serve LSP Content-Length messages until EOF or an exit notification.
  let server = newNimdexLspServer(workers, artifactRoots)
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
