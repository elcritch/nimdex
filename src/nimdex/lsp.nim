## Minimal LSP 3.18 session handling for Nimdex.

import std/[json, os, strutils, syncio, tables]

import sigils
import sigils/rpcs/jsonrpc
import sigils/rpcs/json/jrStdio as jrStdio

import ./bifindex
import ./documents
import ./language
import ./lsptransport
import ./workspace

const
  LspServerNotInitialized* = -32002'i32 ## LSP error for pre-initialization requests.
  LspAnalysisUnavailable* = -32001'i32 ## No compiler-backed snapshot is installed.
  LspServerBusy* = -32003'i32 ## The bounded language queue has no capacity.
  LspRequestCancelled* = -32800'i32 ## LSP cancellation response code.
  LspContentModified* = -32801'i32 ## Work was superseded by a newer stamp.
  LspExitSuccess* = 0 ## Exit status after a valid shutdown and exit sequence.
  LspExitFailure* = 1 ## Exit status when the client exits without shutdown.

type
  LspSessionState* = enum ## Lifecycle states of an LSP server session.
    lssCreated ## No initialize request has been accepted.
    lssInitializing ## Initialize completed; awaiting initialized.
    lssRunning ## The server may process document and language messages.
    lssShuttingDown ## Shutdown completed; awaiting exit.
    lssExited ## The client requested process termination.

  LspPendingRequest = object
    id: JsonNode
    kind: LanguageRequestKind
    stamp: LanguageStamp

  LspQueuedRequest = object
    request: LanguageRequest
    id: JsonNode
    kind: LanguageRequestKind
    stamp: LanguageStamp

  BifIndexCompletion = object
    ok: bool
    snapshot: SemanticSnapshot
    error: string

  BifIndexJob = ref object of AgentActor
    workspace: Workspace
    artifactRoots: seq[string]

  BifIndexTrigger = ref object of AgentActor

  LspServer* = ref object of DynamicAgent ## A Nimdex LSP session and its worker bridge.
    adapter: JsonRpcAdapter
    dispatcher: JsonRpcDispatcher
    language: LanguageRuntime
    home: SigilThreadPtr
    workspace: Workspace
    artifactRoots: seq[string]
    semanticCapabilities: bool
    semanticReady: bool
    semanticLoading: bool
    semanticFailed: bool
    asynchronousSession: bool
    inputStopped: bool
    deferredShutdownResponse: string
    positionEncoding: PositionEncoding
    documentGeneration: uint64
    state: LspSessionState
    exitRequested: bool
    exitStatus: int
    pending: Table[LanguageWorkId, LspPendingRequest]
    pendingByClientId: Table[string, seq[LanguageWorkId]]
    queued: seq[LspQueuedRequest]
    indexThread: ptr SigilThreadDefault
    indexJob: AgentProxy[BifIndexJob]

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

proc indexRequested(source: BifIndexTrigger) {.signal.}
proc indexCompleted(source: BifIndexJob, completion: sink BifIndexCompletion) {.signal.}

proc runBifIndex(job: BifIndexJob) {.slot.} =
  var completion = BifIndexCompletion()
  try:
    completion.snapshot = buildBifIndex(job.workspace, job.artifactRoots)
    completion.ok = true
  except CatchableError as error:
    completion.error = error.msg
  except Defect as error:
    completion.error = "BIF indexing worker failure: " & error.msg
  emit job.indexCompleted(completion)

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

proc parseCancelId(params: JsonNode): JsonNode =
  let root = requireObject(params, "$/cancelRequest params")
  let id = requireMember(root, "id", "$/cancelRequest params")
  if id.kind notin {JNull, JInt, JFloat, JString}:
    raiseLspError(RpcInvalidParams, "$/cancelRequest params.id must be a scalar")
  id

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

proc receiveBifIndexCompletion(
  server: LspServer, completion: BifIndexCompletion
) {.slot.}

proc submitLanguageRequest(
  server: LspServer,
  request: LanguageRequest,
  id: JsonNode,
  kind: LanguageRequestKind,
  stamp: LanguageStamp,
): bool

proc stopSemanticIndex(server: LspServer) =
  if server.indexThread.isNil:
    return
  ## The index job runs on a dedicated Sigils default thread because the
  ## existing BIF batch coordinator pumps its caller while its worker pool
  ## completes. It is never run on a Sigils pool worker.
  server.indexThread.send(ThreadSignal(kind: Exit))
  server.indexThread.join()
  server.indexThread = nil
  server.indexJob = nil

proc startSemanticIndex(server: LspServer) =
  if not server.semanticCapabilities or server.semanticLoading or server.semanticReady:
    return
  server.semanticLoading = true
  server.semanticFailed = false
  let thread = newSigilThread()
  var job =
    BifIndexJob(workspace: server.workspace, artifactRoots: server.artifactRoots)
  let proxy = job.moveToThread(thread)
  server.indexThread = thread
  server.indexJob = proxy
  let trigger = BifIndexTrigger()
  connectThreaded(trigger, indexRequested, proxy, runBifIndex)
  connectThreaded(proxy, indexCompleted, server, receiveBifIndexCompletion(LspServer))
  thread.start()
  emit trigger.indexRequested()

proc currentLanguageStamp(server: LspServer): LanguageStamp =
  LanguageStamp(
    valid: true,
    documentGeneration: server.documentGeneration,
    configurationGeneration: server.workspace.configurationGeneration,
  )

proc stampMatches(a, b: LanguageStamp): bool =
  a.valid == b.valid and (
    not a.valid or (
      a.documentGeneration == b.documentGeneration and
      a.configurationGeneration == b.configurationGeneration
    )
  )

proc responseError(id: JsonNode, code: int32, message: string): string =
  var error = newJObject()
  error["code"] = %code
  error["message"] = %message
  var response = newJObject()
  response["jsonrpc"] = %JsonRpcVersion
  response["error"] = error
  response["id"] =
    if id.isNil:
      newJNull()
    else:
      id
  $response

proc sendError(server: LspServer, id: JsonNode, code: int32, message: string) =
  if not server.dispatcher.isNil:
    server.dispatcher.sendJsonRpcMessage(responseError(id, code, message))

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

const MaxQueuedLspRequests = 512

proc clientIdKey(id: JsonNode): string =
  if id.isNil:
    return "<notification>"
  $id.kind & ":" & $id

proc removeClientWork(server: LspServer, id: JsonNode, workId: LanguageWorkId) =
  let key = clientIdKey(id)
  if key notin server.pendingByClientId:
    return
  var ids = server.pendingByClientId[key]
  var retained: seq[LanguageWorkId]
  for candidate in ids:
    if candidate != workId:
      retained.add(candidate)
  if retained.len == 0:
    server.pendingByClientId.del(key)
  else:
    server.pendingByClientId[key] = retained

proc languageErrorCode(response: LanguageResponse): int32 =
  if response.cancelled:
    return LspRequestCancelled
  if response.superseded:
    return LspContentModified
  if response.error.startsWith("analysis unavailable"):
    return LspAnalysisUnavailable
  RpcInternalError

proc languageResult(kind: LanguageRequestKind, response: LanguageResponse): JsonNode =
  case kind
  of lrkOpen, lrkChange, lrkClose:
    result = newJNull()
  of lrkDocumentSymbols, lrkWorkspaceSymbols:
    result = newJArray()
    for symbol in response.symbols:
      result.add(symbol.lspSymbolInformation())
  of lrkHover:
    if not response.found:
      return newJNull()
    let contents = newJObject()
    contents["kind"] = %"markdown"
    contents["value"] = %response.preview
    result = newJObject()
    result["contents"] = contents
    result["range"] = response.symbols[0].lspRange()

proc successResponse(id, value: JsonNode): string =
  var response = newJObject()
  response["jsonrpc"] = %JsonRpcVersion
  response["result"] = value
  response["id"] = id
  $response

proc finishLanguageWork(server: LspServer) =
  for completion in server.language.takeCompleted():
    if completion.id notin server.pending:
      continue
    let pending = server.pending[completion.id]
    server.pending.del(completion.id)
    server.removeClientWork(pending.id, completion.id)
    if not completion.response.ok:
      server.sendError(
        pending.id,
        completion.response.languageErrorCode(),
        if completion.response.error.len > 0:
          completion.response.error
        else:
          "language request failed",
      )
    elif not completion.response.stamp.stampMatches(pending.stamp):
      server.sendError(
        pending.id, LspContentModified,
        "language result was superseded by newer document or configuration state",
      )
    else:
      server.dispatcher.sendJsonRpcMessage(
        successResponse(pending.id, pending.kind.languageResult(completion.response))
      )
  if server.deferredShutdownResponse.len > 0 and server.pending.len == 0 and
      server.queued.len == 0 and server.language.pendingCount() == 0:
    server.dispatcher.sendJsonRpcMessage(server.deferredShutdownResponse)
    server.deferredShutdownResponse.setLen(0)

proc submitLanguageRequest(
    server: LspServer,
    request: LanguageRequest,
    id: JsonNode,
    kind: LanguageRequestKind,
    stamp: LanguageStamp,
): bool =
  var request = request
  request.stamp = stamp
  let hasResponse = not id.isNil

  if hasResponse and kind in {lrkDocumentSymbols, lrkWorkspaceSymbols, lrkHover} and
      server.semanticCapabilities and not server.semanticReady and
      not server.semanticFailed:
    if server.queued.len >= MaxQueuedLspRequests:
      server.sendError(id, LspServerBusy, "language request queue is full")
      return false
    server.queued.add(
      LspQueuedRequest(request: request, id: id, kind: kind, stamp: stamp)
    )
    return true

  let workId = server.language.submit(request)
  if workId == 0:
    if hasResponse:
      server.sendError(id, LspServerBusy, "language request queue is full")
    else:
      stderr.writeLine("nimdex: language notification queue is full")
    return false
  if not hasResponse:
    return true
  server.pending[workId] = LspPendingRequest(id: id, kind: kind, stamp: stamp)
  server.pendingByClientId.mgetOrPut(clientIdKey(id), @[]).add(workId)
  true

proc cancelQueuedRequest(server: LspServer, id: JsonNode): bool =
  if server.queued.len == 0:
    return false
  for index in countdown(server.queued.len - 1, 0):
    if clientIdKey(server.queued[index].id) == clientIdKey(id):
      server.queued.delete(index)
      server.sendError(id, LspRequestCancelled, "language request was cancelled")
      return true

proc cancelClientRequest(server: LspServer, id: JsonNode) =
  if server.cancelQueuedRequest(id):
    return
  let key = clientIdKey(id)
  if key notin server.pendingByClientId:
    return
  var ids = server.pendingByClientId[key]
  for index in countdown(ids.len - 1, 0):
    let workId = ids[index]
    if workId notin server.pending:
      continue
    if server.language.cancel(workId):
      let pending = server.pending[workId]
      discard server.language.abandon(workId)
      server.pending.del(workId)
      server.removeClientWork(pending.id, workId)
      server.sendError(id, LspRequestCancelled, "language request was cancelled")
      return

proc cancelAllLanguageWork(server: LspServer) =
  for workId, pending in server.pending:
    discard server.language.cancel(workId)
    discard server.language.abandon(workId)
    server.sendError(
      pending.id, LspRequestCancelled,
      "language request was cancelled during server shutdown",
    )
  server.pending.clear()
  server.pendingByClientId.clear()
  for item in server.queued:
    server.sendError(item.id, LspRequestCancelled, "language request was cancelled")
  server.queued.setLen(0)

proc cancelQueuedLanguageWork(server: LspServer) =
  for item in server.queued:
    server.sendError(item.id, LspRequestCancelled, "language request was cancelled")
  server.queued.setLen(0)

proc validJsonRpcId(node: JsonNode): bool =
  not node.isNil and node.kind in {JNull, JInt, JFloat, JString}

proc requestParams(root: JsonNode): JsonNode =
  if root.hasKey("params"):
    root["params"]
  else:
    newJArray()

proc submitAsyncLspRequest(
    server: LspServer, methodName: string, params: JsonNode, id: JsonNode
) =
  let hasResponse = not id.isNil
  try:
    server.requireRunning()
    var request: LanguageRequest
    case methodName
    of "textDocument/didOpen":
      request = parseOpenRequest(params, server.positionEncoding)
    of "textDocument/didChange":
      request = parseChangeRequest(params, server.positionEncoding)
    of "textDocument/didClose":
      request = parseCloseRequest(params)
    of "textDocument/documentSymbol":
      request = parseDocumentSymbolsRequest(params, server.positionEncoding)
    of "workspace/symbol":
      request = parseWorkspaceSymbolsRequest(params, server.positionEncoding)
    of "textDocument/hover":
      request = parseHoverRequest(params, server.positionEncoding)
    else:
      return

    var stamp = server.currentLanguageStamp()
    if request.kind in {lrkOpen, lrkChange, lrkClose}:
      inc stamp.documentGeneration
    let accepted = server.submitLanguageRequest(request, id, request.kind, stamp)
    if accepted and request.kind in {lrkOpen, lrkChange, lrkClose}:
      server.documentGeneration = stamp.documentGeneration
  except RpcRouteError as error:
    if hasResponse:
      server.sendError(id, error.code, error.msg)
  except CatchableError as error:
    if hasResponse:
      server.sendError(id, RpcInvalidParams, error.msg)

proc dispatchIncomingJsonRpc(server: LspServer, data: string) =
  ## Route lifecycle and protocol errors through Sigils' normal adapter. Only
  ## language operations that need deferred completion take the Nimdex-owned
  ## path below.
  var root: JsonNode
  try:
    root = parseJson(data)
  except CatchableError:
    let response = server.adapter.handleJsonRpc(data)
    if response.isSome():
      server.dispatcher.sendJsonRpcMessage(response.get())
    return

  if root.kind != JObject or not root.hasKey("method") or root["method"].kind != JString or
      (root.hasKey("id") and not root["id"].validJsonRpcId()):
    let response = server.adapter.handleJsonRpc(data)
    if response.isSome():
      server.dispatcher.sendJsonRpcMessage(response.get())
    return

  let methodName = root["method"].getStr()
  let id =
    if root.hasKey("id"):
      root["id"]
    else:
      nil
  if methodName == "$/cancelRequest" and id.isNil:
    try:
      server.cancelClientRequest(parseCancelId(root.requestParams()))
    except CatchableError:
      discard
    return

  if methodName == "shutdown":
    let response = server.adapter.handleJsonRpc(data)
    if response.isSome():
      if server.pending.len > 0 or server.queued.len > 0 or
          server.language.pendingCount() > 0:
        server.deferredShutdownResponse = response.get()
      else:
        server.dispatcher.sendJsonRpcMessage(response.get())
    return

  if methodName == "textDocument/didOpen" or methodName == "textDocument/didChange" or
      methodName == "textDocument/didClose" or
      methodName == "textDocument/documentSymbol" or methodName == "workspace/symbol" or
      methodName == "textDocument/hover":
    server.submitAsyncLspRequest(methodName, root.requestParams(), id)
    return

  let response = server.adapter.handleJsonRpc(data)
  if response.isSome():
    server.dispatcher.sendJsonRpcMessage(response.get())

proc receiveJsonRpcRequest(server: LspServer, request: JsonRpcRequest) {.slot.} =
  if server.isNil or server.dispatcher.isNil:
    return
  server.finishLanguageWork()
  server.dispatchIncomingJsonRpc(request.data)
  server.finishLanguageWork()

proc receiveJsonRpcStopped(server: LspServer) {.slot.} =
  if not server.isNil:
    server.inputStopped = true

proc receiveBifIndexCompletion(
    server: LspServer, completion: BifIndexCompletion
) {.slot.} =
  if server.isNil:
    return
  server.semanticLoading = false
  if completion.ok:
    server.language.installIndex(completion.snapshot)
    server.semanticReady = true
  else:
    server.semanticFailed = true

  server.stopSemanticIndex()

  if server.queued.len == 0:
    return
  let queued = move(server.queued)
  for item in queued:
    if not completion.ok:
      server.sendError(
        item.id,
        LspAnalysisUnavailable,
        "analysis unavailable: " &
          (
            if completion.error.len > 0: completion.error
            else: "BIF index is unavailable"
          ),
      )
      continue
    discard server.submitLanguageRequest(item.request, item.id, item.kind, item.stamp)

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
  if server.asynchronousSession:
    server.startSemanticIndex()
  else:
    server.installSemanticIndex()
  newJNull()

proc shutdownLsp(server: LspServer, params: JsonNode): JsonNode =
  discard params
  server.requireRunning()
  server.cancelQueuedLanguageWork()
  server.state = lssShuttingDown
  newJNull()

proc exitLsp(server: LspServer, params: JsonNode): JsonNode =
  discard params
  server.cancelQueuedLanguageWork()
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
    pending: initTable[LanguageWorkId, LspPendingRequest](),
    pendingByClientId: initTable[string, seq[LanguageWorkId]](),
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
  ## Cancel protocol work and stop all worker/coordinator threads owned by the server.
  if not server.isNil:
    server.cancelAllLanguageWork()
    server.stopSemanticIndex()
    server.language.close()

proc runNimdexLspStdio*(
    input: File = stdin,
    output: File = stdout,
    workers = 1,
    artifactRoots: seq[string] = @[],
): int =
  ## Serve LSP Content-Length messages until EOF or an exit notification.
  ##
  ## Input and output deliberately have different owners: the reader actor can
  ## block in File.readChar while the home thread continues to dispatch worker
  ## completions and flush framed responses.
  let server = newNimdexLspServer(workers, artifactRoots)
  server.asynchronousSession = true
  let dispatcher = newJsonRpcDispatcher(server.adapter)
  server.dispatcher = dispatcher
  let writer = jrStdio.newJsonRpcStdioIo(input, output)
  let readerThread = newSigilThread()
  var reader = newNimdexLspStdioReader(input)
  let readerProxy = reader.moveToThread(readerThread)

  connect(
    dispatcher, jsonRpcResponseReady, writer, JsonRpcIoAgent.sendJsonRpcResponse()
  )
  connectThreaded(
    readerProxy, jsonRpcRequestReceived, server, receiveJsonRpcRequest(LspServer)
  )
  connectThreaded(readerProxy, jsonRpcStopped, server, receiveJsonRpcStopped(LspServer))
  connectThreaded(
    dispatcher, jsonRpcStartRequested, readerProxy, JsonRpcIoAgent.startJsonRpcIo()
  )
  connectThreaded(
    dispatcher, jsonRpcStopRequested, readerProxy, JsonRpcIoAgent.stopJsonRpcIo()
  )
  connectThreaded(
    readerProxy, jsonRpcStarted, dispatcher, JsonRpcDispatcher.recordJsonRpcStarted()
  )
  connectThreaded(
    readerProxy, jsonRpcStopped, dispatcher, JsonRpcDispatcher.recordJsonRpcStopped()
  )

  writer.startIo()
  readerThread.start()
  emit dispatcher.jsonRpcStartRequested()

  try:
    while true:
      let processed = server.home.pollAll(NonBlocking)
      server.finishLanguageWork()
      if server.isExitRequested():
        if server.pending.len == 0 and server.queued.len == 0 and
            server.language.pendingCount() == 0:
          break
      elif server.inputStopped:
        server.exitStatus = LspExitFailure
        server.cancelAllLanguageWork()
        break
      if processed == 0:
        discard server.home.poll(Blocking)
  finally:
    if not readerThread.isNil:
      readerThread.send(ThreadSignal(kind: Exit))
      readerThread.join()
    server.close()
    writer.stopIo()

  server.exitStatus()
