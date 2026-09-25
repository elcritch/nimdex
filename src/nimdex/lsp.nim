## Minimal LSP 3.18 session handling for Nimdex.

import std/[algorithm, json, os, sequtils, strutils, syncio, tables, monotimes, times]

import chronicles
import sigils
import sigils/rpcs/jsonrpc
import sigils/rpcs/json/jrStdio as jrStdio

import ./workerlife

import ./bifindex
import ./compiler
import ./documents
import ./language
import ./lsptransport
import ./workspace

export DefaultNimdexMessageSize

const
  LspServerNotInitialized* = -32002'i32 ## LSP error for pre-initialization requests.
  LspAnalysisUnavailable* = -32001'i32 ## No compiler-backed snapshot is installed.
  LspServerBusy* = -32003'i32 ## The bounded language queue has no capacity.
  LspCompilerUnavailable* = -32004'i32 ## The required Nim compiler is unavailable.
  LspDebugMethod* = "nimdex/debug" ## Nimdex diagnostics/introspection method.
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

  CompilerRefreshCompletion = object
    result: CompilerRefreshResult

  CompilerRefreshJob = ref object of AgentActor
    request: CompilerRefreshRequest

  CompilerRefreshTrigger = ref object of AgentActor

  LspServer* = ref object of DynamicAgent ## A Nimdex LSP session and its worker bridge.
    adapter: JsonRpcAdapter
    dispatcher: JsonRpcDispatcher
    writer: JsonRpcIoAgent
    language: LanguageRuntime
    home: SigilThreadPtr
    workspace: Workspace
    artifactRoots: seq[string]
    configuredCompilerPath: string
    configuredCompilerFrontend: CompilerFrontend
    compiler: CompilerCapabilities
    compilerEnabled: bool
    semanticCapabilities: bool
    semanticReady: bool
    semanticLoading: bool
    semanticFailed: bool
    asynchronousSession: bool
    inputStopped: bool
    deferredShutdownResponse: string
    positionEncoding: PositionEncoding
    openDocuments: DocumentStore
    overlayIdentity: uint64
    refreshDeadline: int64
    documentGeneration: uint64
    compilerSourceGeneration: uint64
    state: LspSessionState
    exitRequested: bool
    exitStatus: int
    pending: Table[LanguageWorkId, LspPendingRequest]
    pendingByClientId: Table[string, seq[LanguageWorkId]]
    queued: seq[LspQueuedRequest]
    indexThread: ptr SigilThreadDefault
    indexJob: AgentProxy[BifIndexJob]
    retiredThreads: seq[SigilThreadDefaultPtr]
    compilerThread: ptr SigilThreadDefault
    compilerJob: AgentProxy[CompilerRefreshJob]
    compilerCancellation: CompilerCancellation
    compilerLoading: bool
    compilerRefreshPending: bool
    publishedDiagnosticUris: Table[string, bool]
    activeSnapshot: SemanticSnapshot
    compilerHeads: seq[HeadAnalysis]
    savedHeads: seq[HeadAnalysis]
    refreshEntryPoints: seq[string]
    progressHeads: seq[HeadAnalysis]
    progressSnapshot: SemanticSnapshot
    progressSnapshotStarted: bool
    progressUsesPrevious: bool
    completedHeads: seq[string]
    failedHeads: seq[string]
    headDiagnostics: Table[string, seq[CompilerDiagnostic]]
    preferredHeads: Table[string, string]
    activeDocument: string
    forceCompilerRefresh: bool
    lastCompiledHeads: int
    lastReusedHeads: int
    lastLoadedArtifacts: int
    lastReusedArtifacts: int
    lastRestoredHeads: int
    lastCompilerCachePath: string
    lastCompilerCommands: seq[string]
    lastCompilerArtifacts: seq[string]
    lastCompilerExitCode: int
    lastCompilerStdoutBytes: int
    lastCompilerStderrBytes: int
    lastCompilerError: string
    lastCompilerCancelled: bool

let
  initializeSelector = selector[JsonNode, JsonNode]("initialize")
  initializedSelector = selector[JsonNode, JsonNode]("initialized")
  shutdownSelector = selector[JsonNode, JsonNode]("shutdown")
  exitSelector = selector[JsonNode, JsonNode]("exit")
  didOpenSelector = selector[JsonNode, JsonNode]("textDocument/didOpen")
  didChangeSelector = selector[JsonNode, JsonNode]("textDocument/didChange")
  didCloseSelector = selector[JsonNode, JsonNode]("textDocument/didClose")
  didSaveSelector = selector[JsonNode, JsonNode]("textDocument/didSave")
  didChangeWatchedFilesSelector =
    selector[JsonNode, JsonNode]("workspace/didChangeWatchedFiles")
  documentSymbolSelector = selector[JsonNode, JsonNode]("textDocument/documentSymbol")
  workspaceSymbolSelector = selector[JsonNode, JsonNode]("workspace/symbol")
  definitionSelector = selector[JsonNode, JsonNode]("textDocument/definition")
  hoverSelector = selector[JsonNode, JsonNode]("textDocument/hover")
  debugSelector = selector[JsonNode, JsonNode](LspDebugMethod)

proc indexRequested(source: BifIndexTrigger) {.signal.}
proc indexCompleted(source: BifIndexJob, completion: sink BifIndexCompletion) {.signal.}
proc compilerRefreshRequested(source: CompilerRefreshTrigger) {.signal.}
proc compilerRefreshCompleted(
  source: CompilerRefreshJob, completion: sink CompilerRefreshCompletion
) {.signal.}

proc compilerHeadCompleted(
  source: CompilerRefreshJob, progress: CompilerHeadProgress
) {.signal.}

proc symbolCount(snapshot: SemanticSnapshot): int

proc runBifIndex(job: BifIndexJob) {.slot.} =
  var completion = BifIndexCompletion()
  info "Starting configured BIF index job",
    projectId = job.workspace.projectId,
    workspaceRoot = job.workspace.rootPath,
    artifactRoots = job.artifactRoots
  try:
    completion.snapshot = buildBifIndex(job.workspace, job.artifactRoots)
    completion.ok = true
    info "Configured BIF index job completed",
      projectId = job.workspace.projectId,
      moduleCount = completion.snapshot.moduleCount(),
      symbolCount = completion.snapshot.symbolCount(),
      tokenCount = completion.snapshot.tokenCount(),
      failureCount = completion.snapshot.failureCount()
  except CatchableError as error:
    completion.error = error.msg
    warn "Configured BIF index job failed",
      projectId = job.workspace.projectId, failure = error.msg
  except Defect as error:
    completion.error = "BIF indexing worker failure: " & error.msg
    warn "Configured BIF index worker failed",
      projectId = job.workspace.projectId, failure = error.msg
  emit job.indexCompleted(completion)

proc compilerFailure(
    request: CompilerRefreshRequest, message: string
): CompilerRefreshResult =
  result.compiler = request.capabilities
  result.stamp = AnalysisStamp(
    valid: true,
    projectId: request.workspace.projectId,
    documentGeneration: request.documentGeneration,
    sourceGeneration: request.sourceGeneration,
    configurationGeneration: request.workspace.configurationGeneration,
    configurationFingerprint: request.workspace.configurationFingerprint,
    compilerFingerprint: request.capabilities.fingerprint,
  )
  result.error = message
  let entryPoints = discoverCompilerEntryPoints(request.workspace)
  let sourcePath =
    if entryPoints.len > 0:
      entryPoints[0]
    else:
      request.workspace.rootPath
  result.diagnostics.add(
    CompilerDiagnostic(
      sourcePath: sourcePath,
      sourceUri: documentUriFromPath(sourcePath),
      severity: cdsError,
      message: message,
    )
  )

proc runCompilerRefresh(job: CompilerRefreshJob) {.slot.} =
  var completion = CompilerRefreshCompletion()
  try:
    completion.result = runCompilerRefresh(
      job.request,
      proc(progress: CompilerHeadProgress) =
        emit job.compilerHeadCompleted(progress)
      ,
    )
  except CatchableError as error:
    completion.result = compilerFailure(job.request, error.msg)
  except Defect as error:
    completion.result =
      compilerFailure(job.request, "compiler refresh worker failure: " & error.msg)
  emit job.compilerRefreshCompleted(completion)

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

type CompilerInitializeOptions = object
  configured: bool
  autoCompileSet: bool
  autoCompile: bool
  compilerPath: string
  compilerFrontend: CompilerFrontend
  cacheRoot: string
  entryPoints: seq[string]
  importPaths: seq[string]
  nimArguments: seq[string]
  preferredHeads: Table[string, string]

proc initializationOptions(params: JsonNode): JsonNode =
  if params.kind == JObject and params.hasKey("initializationOptions"):
    return params["initializationOptions"]
  newJObject()

proc compilerOptionsFromInitialize(
    params: JsonNode, serverCompilerPath: string, serverFrontend: CompilerFrontend
): CompilerInitializeOptions =
  let options = initializationOptions(params)
  result.compilerFrontend = serverFrontend
  if serverCompilerPath.len > 0 or serverFrontend != cfCompile:
    result.configured = true
  if options.kind != JObject:
    if serverCompilerPath.len > 0:
      result.configured = true
      result.compilerPath = serverCompilerPath
    return

  result.compilerPath = serverCompilerPath
  if options.hasKey("compilerFrontend"):
    result.configured = true
    let frontend =
      requireString(options, "compilerFrontend", "initialize initializationOptions")
    case frontend
    of "compile":
      result.compilerFrontend = cfCompile
    of "track":
      result.compilerFrontend = cfTrack
    else:
      raiseLspError(RpcInvalidParams, "compilerFrontend must be compile or track")
  if options.hasKey("compiler"):
    result.configured = true
    let compiler = options["compiler"]
    case compiler.kind
    of JString:
      result.compilerPath = compiler.getStr()
    of JObject:
      if compiler.hasKey("path"):
        if compiler["path"].kind != JString:
          raiseLspError(RpcInvalidParams, "initialize compiler.path must be a string")
        result.compilerPath = compiler["path"].getStr()
      elif compiler.hasKey("compilerPath"):
        if compiler["compilerPath"].kind != JString:
          raiseLspError(
            RpcInvalidParams, "initialize compiler.compilerPath must be a string"
          )
        result.compilerPath = compiler["compilerPath"].getStr()
    else:
      raiseLspError(
        RpcInvalidParams,
        "initialize initializationOptions.compiler must be a string or object",
      )
  if options.hasKey("compilerPath"):
    result.configured = true
    if options["compilerPath"].kind != JString:
      raiseLspError(
        RpcInvalidParams,
        "initialize initializationOptions.compilerPath must be a string",
      )
    result.compilerPath = options["compilerPath"].getStr()
  if options.hasKey("cacheRoot"):
    result.configured = true
    result.cacheRoot =
      requireString(options, "cacheRoot", "initialize initializationOptions")
  if options.hasKey("entryPoints"):
    result.configured = true
    result.entryPoints =
      stringArray(options, "entryPoints", "initialize initializationOptions")
  if options.hasKey("importPaths"):
    result.configured = true
    result.importPaths =
      stringArray(options, "importPaths", "initialize initializationOptions")
  if options.hasKey("nimArguments"):
    result.configured = true
    result.nimArguments =
      stringArray(options, "nimArguments", "initialize initializationOptions")
  if options.hasKey("preferredHeads"):
    let choices = requireObject(options["preferredHeads"], "initialize preferredHeads")
    for source, head in choices:
      if head.kind != JString:
        raiseLspError(RpcInvalidParams, "preferredHeads values must be head paths")
      result.preferredHeads[source] = head.getStr()
  if options.hasKey("autoCompile"):
    if options["autoCompile"].kind != JBool:
      raiseLspError(
        RpcInvalidParams,
        "initialize initializationOptions.autoCompile must be a boolean",
      )
    result.autoCompileSet = true
    result.autoCompile = options["autoCompile"].getBool()
    result.configured = result.autoCompile

proc resolveWorkspacePaths(rootUri: string, paths: openArray[string]): seq[string] =
  let rootPath = pathFromDocumentUri(rootUri)
  for path in paths:
    if path.len == 0:
      continue
    result.add(
      if rootPath.len > 0 and not isAbsolute(path):
        normalizeDocumentPath(rootPath / path)
      else:
        normalizeDocumentPath(path)
    )

proc resolveCompilerPath(rootUri, path: string): string =
  if path.len == 0:
    return
  let rootPath = pathFromDocumentUri(rootUri)
  if rootPath.len > 0 and not isAbsolute(path) and (DirSep in path or AltSep in path):
    return normalizeDocumentPath(rootPath / path)
  path

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

proc addJsonStrings(node: JsonNode, name: string, values: openArray[string]) =
  var array = newJArray()
  for value in values:
    array.add(%value)
  node[name] = array

proc addUniquePath(paths: var seq[string], path: string) =
  if path.len == 0:
    return
  let normalized = normalizeDocumentPath(path)
  if normalized.len > 0 and normalized notin paths:
    paths.add(normalized)

proc configurationPaths(server: LspServer): seq[string] =
  var roots: seq[string]
  roots.add(server.workspace.rootPath)
  roots.add(server.workspace.importPaths)
  for root in roots:
    if root.len == 0:
      continue
    var current = normalizeDocumentPath(root)
    while current.len > 0:
      for name in ["nim.cfg", "config.nims"]:
        let candidate = current / name
        if fileExists(candidate):
          result.addUniquePath(candidate)
      if dirExists(current):
        for kind, path in walkDir(current):
          if kind != pcFile:
            continue
          let extension = path.splitFile().ext.toLowerAscii()
          if extension == ".nimble":
            result.addUniquePath(path)
      let parent = current.parentDir
      if parent == current:
        break
      current = parent

proc compilerLibraryPaths(server: LspServer): seq[string] =
  if server.compiler.compilerPath.len > 0:
    let compilerRoot = server.compiler.compilerPath.parentDir.parentDir
    let standardLibrary = compilerRoot / "lib"
    if dirExists(standardLibrary):
      result.addUniquePath(standardLibrary)
  if server.workspace.rootPath.len > 0:
    let projectLibrary = server.workspace.rootPath / "lib"
    if dirExists(projectLibrary):
      result.addUniquePath(projectLibrary)
  for path in server.workspace.importPaths:
    result.addUniquePath(path)

proc symbolCount(snapshot: SemanticSnapshot): int =
  for module in snapshot.modules:
    result += module.symbols.len

proc debugLsp(server: LspServer, params: JsonNode): JsonNode =
  discard params
  server.requireRunning()

  result = newJObject()
  result["method"] = %LspDebugMethod

  let workspace = newJObject()
  workspace["rootUri"] = %server.workspace.rootUri
  workspace["rootPath"] = %server.workspace.rootPath
  workspace["projectId"] = %server.workspace.projectId
  workspace["cacheRoot"] = %server.workspace.cacheRoot
  workspace["configurationGeneration"] = %server.workspace.configurationGeneration
  workspace["configurationFingerprint"] = %($server.workspace.configurationFingerprint)
  addJsonStrings(
    workspace, "entryPoints", server.workspace.discoverCompilerEntryPoints()
  )
  let layout = discoverProjectLayout(server.workspace.rootPath)
  addJsonStrings(workspace, "packageFiles", layout.packageFiles)
  addJsonStrings(workspace, "sourceDirs", layout.sourceDirs)
  addJsonStrings(workspace, "discoveryWarnings", layout.warnings)
  addJsonStrings(workspace, "importPaths", server.workspace.importPaths)
  addJsonStrings(workspace, "nimArguments", server.workspace.nimArguments)
  addJsonStrings(workspace, "artifactRoots", server.workspace.artifactRoots)
  result["workspace"] = workspace

  let compiler = newJObject()
  compiler["path"] = %server.compiler.compilerPath
  compiler["version"] = %server.compiler.version
  compiler["revision"] = %server.compiler.revision
  compiler["available"] = %server.compiler.available
  compiler["supportsGenBif"] = %server.compiler.supportsGenBif
  compiler["frontend"] = %($server.workspace.compilerFrontend)
  compiler["supportsTrack"] = %server.compiler.supportsTrack
  compiler["niflerPath"] = %server.compiler.niflerPath
  compiler["nifmakePath"] = %server.compiler.nifmakePath
  compiler["fingerprint"] = %($server.compiler.fingerprint)
  compiler["enabled"] = %server.compilerEnabled
  compiler["error"] = %server.compiler.error
  result["compiler"] = compiler

  let paths = newJObject()
  addJsonStrings(paths, "libraryPaths", server.compilerLibraryPaths())
  addJsonStrings(paths, "configurationPaths", server.configurationPaths())
  result["paths"] = paths

  let refresh = newJObject()
  refresh["openBuffers"] = %server.openDocuments.len
  refresh["debouncing"] = %(server.refreshDeadline > 0)
  refresh["retiredWorkers"] = %server.retiredThreads.len
  refresh["cachePath"] = %server.lastCompilerCachePath
  refresh["exitCode"] = %server.lastCompilerExitCode
  refresh["stdoutBytes"] = %server.lastCompilerStdoutBytes
  refresh["stderrBytes"] = %server.lastCompilerStderrBytes
  refresh["error"] = %server.lastCompilerError
  refresh["cancelled"] = %server.lastCompilerCancelled
  refresh["compiledHeads"] = %server.lastCompiledHeads
  refresh["reusedHeads"] = %server.lastReusedHeads
  refresh["restoredHeads"] = %server.lastRestoredHeads
  addJsonStrings(refresh, "completedHeads", server.completedHeads)
  addJsonStrings(
    refresh,
    "pendingHeads",
    server.refreshEntryPoints.filterIt(it notin server.completedHeads),
  )
  addJsonStrings(refresh, "failedHeads", server.failedHeads)
  refresh["loadedArtifacts"] = %server.lastLoadedArtifacts
  refresh["reusedArtifacts"] = %server.lastReusedArtifacts
  addJsonStrings(refresh, "commandLines", server.lastCompilerCommands)
  addJsonStrings(refresh, "artifactPaths", server.lastCompilerArtifacts)
  result["refresh"] = refresh

  var semanticNode: JsonNode = newJObject()
  semanticNode["ready"] = %server.semanticReady
  semanticNode["loading"] = %(server.semanticLoading or server.refreshDeadline > 0)
  semanticNode["failed"] = %server.semanticFailed
  semanticNode["moduleCount"] = %server.activeSnapshot.moduleCount()
  semanticNode["symbolCount"] = %server.activeSnapshot.symbolCount()
  semanticNode["tokenCount"] = %server.activeSnapshot.tokenCount()
  semanticNode["failureCount"] = %server.activeSnapshot.failureCount()
  semanticNode["sourceFingerprint"] = %($server.activeSnapshot.sourceFingerprint)
  result["semantic"] = semanticNode
  if params.kind == JObject and params.hasKey("summaryOnly"):
    if params["summaryOnly"].kind != JBool:
      raiseLspError(RpcInvalidParams, "debug summaryOnly must be a boolean")
    if params["summaryOnly"].getBool():
      return
  var modules = newJArray()
  for module in server.activeSnapshot.modules:
    let value = newJObject()
    value["artifactPath"] = %module.artifactPath
    value["moduleId"] = %module.moduleId
    value["artifactHash"] = %module.artifactHash
    addJsonStrings(value, "headFiles", module.headFiles)
    addJsonStrings(value, "imports", module.imports)
    addJsonStrings(value, "includes", module.includes)
    value["sourcePath"] = %module.sourcePath
    value["sourceUri"] = %module.sourceUri
    value["tokenCount"] = %module.tokenCount
    value["tagCount"] = %module.tagCount
    value["stringCount"] = %module.stringCount
    value["symbolPoolCount"] = %module.symbolPoolCount
    value["filenameCount"] = %module.filenameCount
    value["symbolCount"] = %module.symbols.len
    addJsonStrings(value, "sourceFiles", module.sourceFiles)
    addJsonStrings(value, "tags", module.tags)
    modules.add(value)
  semanticNode["modules"] = modules
  result["semantic"] = semanticNode
  let graph = newJObject()
  addJsonStrings(graph, "actualHeads", server.activeSnapshot.graph.heads)
  var sources: seq[string]
  for path in server.activeSnapshot.graph.sourceHeads.keys:
    sources.add(path)
  sources.sort()
  var nodes = newJArray()
  for path in sources:
    let node = newJObject()
    node["sourcePath"] = %path
    addJsonStrings(node, "headFiles", server.activeSnapshot.graph.headsFor(path))
    node["preferredHead"] =
      %server.preferredHeads.getOrDefault(
        path, server.activeSnapshot.graph.preferredHead(path)
      )
    let dependencies = server.activeSnapshot.graph.modules.getOrDefault(path)
    addJsonStrings(node, "imports", dependencies.imports)
    addJsonStrings(node, "includes", dependencies.includes)
    addJsonStrings(node, "unresolvedImports", dependencies.unresolvedImports)
    addJsonStrings(
      node, "importers", server.activeSnapshot.graph.importers.getOrDefault(path)
    )
    nodes.add(node)
  graph["modules"] = nodes
  result["moduleGraph"] = graph

proc installSemanticIndex(server: LspServer) =
  if not server.semanticCapabilities:
    return
  try:
    var snapshot = buildBifIndex(server.workspace, server.artifactRoots)
    server.activeSnapshot = snapshot
    server.language.installIndex(snapshot)
    server.semanticReady = true
    server.semanticFailed = false
  except CatchableError as error:
    ## Capability advertisement remains useful when a refresh cannot be
    ## completed, but the language actor will correctly return no results
    ## until a complete snapshot is installed.
    warn "Unable to install semantic index",
      projectId = server.workspace.projectId, failure = error.msg

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

proc initializeLsp(server: LspServer, params: JsonNode): JsonNode

proc reapWorkers(server: LspServer) =
  var retained: seq[SigilThreadDefaultPtr]
  for thread in server.retiredThreads:
    if not thread.disposeJoined():
      retained.add(thread)
  server.retiredThreads = move(retained)

proc stopSemanticIndex(server: LspServer) =
  if server.indexThread.isNil:
    return
  ## The index job runs on a dedicated Sigils default thread because the
  ## existing BIF batch coordinator pumps its caller while its worker pool
  ## completes. It is never run on a Sigils pool worker.
  server.indexThread.send(ThreadSignal(kind: Exit))
  server.indexThread.join()
  server.indexJob = nil
  server.retiredThreads.add(server.indexThread)
  server.indexThread = nil

proc startSemanticIndex(server: LspServer) =
  if not server.semanticCapabilities or server.semanticLoading or server.semanticReady:
    return
  server.semanticLoading = true
  server.semanticFailed = false
  info "Starting semantic index",
    projectId = server.workspace.projectId,
    workspaceRoot = server.workspace.rootPath,
    artifactRoots = server.artifactRoots
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

proc stopCompilerRefresh(server: LspServer) =
  if not server.compilerThread.isNil:
    server.compilerCancellation.cancelCompiler()
    server.compilerThread.send(ThreadSignal(kind: Exit))
    server.compilerThread.join()
    server.compilerJob = nil
    server.retiredThreads.add(server.compilerThread)
    server.compilerThread = nil
  if not server.compilerCancellation.isNil:
    server.compilerCancellation.releaseCompilerCancellation()
    server.compilerCancellation = nil
  server.compilerLoading = false

proc compilerDiagnosticPosition(
    server: LspServer, diagnostic: CompilerDiagnostic
): tuple[start, finish: TextPosition] =
  result.start = TextPosition(line: 0, character: 0)
  result.finish = result.start
  if diagnostic.sourcePath.len == 0 or not diagnostic.hasLocation or (
    not fileExists(diagnostic.sourcePath) and
    not server.openDocuments.containsDocument(diagnostic.sourceUri)
  ):
    result.start = TextPosition(
      line: max(int(diagnostic.line) - 1, 0), character: max(int(diagnostic.column), 0)
    )
    result.finish = result.start
    return
  try:
    var document: DocumentSnapshot
    if not server.openDocuments.tryFindDocument(diagnostic.sourceUri, document):
      document = initDocumentSnapshot(
        diagnostic.sourceUri,
        readFile(diagnostic.sourcePath),
        0,
        server.positionEncoding,
      )
    let line = max(int(diagnostic.line) - 1, 0)
    let offset = document.lineStartOffset(line) + max(int(diagnostic.column), 0)
    if not document.tryPositionAt(offset, result.start):
      result.start = TextPosition(line: line, character: 0)
    let finishOffset = min(offset + 1, document.lineEndOffset(line))
    if not document.tryPositionAt(finishOffset, result.finish):
      result.finish = result.start
  except CatchableError:
    discard

proc lspPosition(position: TextPosition): JsonNode

proc compilerDiagnosticSeverity(diagnostic: CompilerDiagnostic): int =
  case diagnostic.severity
  of cdsError: 1
  of cdsWarning: 2
  of cdsInformation: 3
  of cdsHint: 4

proc compilerDiagnosticJson(
    server: LspServer, diagnostic: CompilerDiagnostic
): JsonNode =
  let positions = server.compilerDiagnosticPosition(diagnostic)
  result = newJObject()
  let range = newJObject()
  range["start"] = lspPosition(positions.start)
  range["end"] = lspPosition(positions.finish)
  result["range"] = range
  result["severity"] = %diagnostic.compilerDiagnosticSeverity()
  result["source"] = %"nim"
  result["message"] = %diagnostic.message

proc publishCompilerDiagnostics(
    server: LspServer, diagnostics: openArray[CompilerDiagnostic]
) =
  if server.dispatcher.isNil:
    return
  var grouped = initTable[string, seq[CompilerDiagnostic]]()
  for diagnostic in diagnostics:
    let uri =
      if diagnostic.sourceUri.len > 0:
        diagnostic.sourceUri
      elif diagnostic.sourcePath.len > 0:
        documentUriFromPath(diagnostic.sourcePath)
      else:
        server.workspace.rootUri
    if uri.len > 0:
      if diagnostic notin grouped.mgetOrPut(uri, @[]):
        grouped[uri].add(diagnostic)

  var uris = initTable[string, bool]()
  for uri in server.publishedDiagnosticUris.keys:
    uris[uri] = true
  for uri in grouped.keys:
    uris[uri] = true

  for uri in uris.keys:
    var params = newJObject()
    params["uri"] = %uri
    var document: DocumentSnapshot
    if server.openDocuments.tryFindDocument(uri, document):
      params["version"] = %document.version
    var values = newJArray()
    if uri in grouped:
      for diagnostic in grouped[uri]:
        values.add(server.compilerDiagnosticJson(diagnostic))
    params["diagnostics"] = values
    server.dispatcher.sendJsonRpcNotification("textDocument/publishDiagnostics", params)

  server.publishedDiagnosticUris.clear()
  for uri in grouped.keys:
    server.publishedDiagnosticUris[uri] = true

proc receiveCompilerRefreshCompletion(
  server: LspServer, completion: CompilerRefreshCompletion
) {.slot.}

proc receiveCompilerHeadProgress(
  server: LspServer, progress: CompilerHeadProgress
) {.slot.}

proc runCompilerRefreshSynchronously(server: LspServer)

proc headForDocument(server: LspServer, path: string): string =
  if path.len == 0:
    return
  if path in server.preferredHeads:
    return server.preferredHeads[path]
  let known = server.activeSnapshot.graph.preferredHead(path)
  if known.len > 0 and known in server.refreshEntryPoints:
    return known
  var best = -1
  for head in server.refreshEntryPoints:
    if head == path:
      return head
    let score = if path.startsWith(head.parentDir & DirSep): head.parentDir.len else: 0
    if score > best:
      best = score
      result = head

proc prioritizeDocument(server: LspServer, uri: string) =
  server.activeDocument = pathFromDocumentUri(uri)
  let head = server.headForDocument(server.activeDocument)
  server.compilerCancellation.prioritizeCompilerHead(
    server.refreshEntryPoints.find(head)
  )

proc documentHasAnalysis(server: LspServer, uri: string): bool =
  let path = pathFromDocumentUri(uri)
  let owners = server.activeSnapshot.graph.headsFor(path)
  let chosen = server.preferredHeads.getOrDefault(
    path, server.activeSnapshot.graph.preferredHead(path)
  )
  owners.len > 0 and (
    chosen.len == 0 or (
      chosen in owners and chosen notin server.failedHeads and
      (not server.compilerLoading or chosen in server.completedHeads)
    )
  )

proc prepareCompilerRefresh(server: LspServer) =
  server.refreshEntryPoints = server.workspace.discoverCompilerEntryPoints()
  server.savedHeads =
    server.savedHeads.filterIt(it.headPath in server.refreshEntryPoints)
  server.progressUsesPrevious =
    server.semanticReady and
    server.activeSnapshot.graph.heads == server.refreshEntryPoints
  server.progressSnapshotStarted = false
  server.semanticReady = false
  server.semanticFailed = false
  server.progressHeads.setLen(0)
  server.completedHeads.setLen(0)
  server.failedHeads.setLen(0)
  server.headDiagnostics.clear()

proc reusableHeads(server: LspServer): seq[HeadAnalysis] =
  result = server.compilerHeads
  for saved in server.savedHeads:
    var retained = false
    for head in result:
      if head.headPath == saved.headPath and head.overlayFingerprint == 0:
        retained = true
        break
    if not retained:
      result.add(saved)

proc startCompilerRefresh(server: LspServer) =
  if not server.compilerEnabled or server.compilerLoading:
    return
  server.compilerLoading = true
  server.semanticLoading = true
  server.prepareCompilerRefresh()
  info "Starting compiler refresh",
    projectId = server.workspace.projectId,
    workspaceRoot = server.workspace.rootPath,
    compilerPath = server.compiler.compilerPath,
    entryPoints = server.workspace.entryPoints,
    importPaths = server.workspace.importPaths,
    cacheRoot = server.workspace.cacheRoot
  if not server.semanticReady:
    server.semanticFailed = false
  server.compilerRefreshPending = false
  let cancellation = newCompilerCancellation()
  server.compilerCancellation = cancellation
  let thread = newSigilThread()
  let request = CompilerRefreshRequest(
    workspace: server.workspace,
    capabilities: server.compiler,
    documentGeneration: server.documentGeneration,
    sourceGeneration: server.compilerSourceGeneration,
    cancellation: cancellation,
    previousHeads: server.reusableHeads(),
    overlays: server.openDocuments.dirtyDocuments(),
    forceRebuild: server.forceCompilerRefresh,
    priorityHead: server.headForDocument(server.activeDocument),
  )
  server.forceCompilerRefresh = false
  var job = CompilerRefreshJob(request: request)
  let proxy = job.moveToThread(thread)
  server.compilerThread = thread
  server.compilerJob = proxy
  let trigger = CompilerRefreshTrigger()
  connectThreaded(trigger, compilerRefreshRequested, proxy, runCompilerRefresh)
  connectThreaded(
    proxy, compilerRefreshCompleted, server, receiveCompilerRefreshCompletion(LspServer)
  )
  connectThreaded(
    proxy, compilerHeadCompleted, server, receiveCompilerHeadProgress(LspServer)
  )
  thread.start()
  emit trigger.compilerRefreshRequested()

proc requestCompilerRefresh(server: LspServer) =
  if not server.compilerEnabled:
    return
  server.refreshDeadline = 0
  if server.compilerLoading:
    server.compilerRefreshPending = true
    server.compilerCancellation.cancelCompiler()
  elif server.asynchronousSession:
    server.startCompilerRefresh()
  else:
    server.runCompilerRefreshSynchronously()

proc validBufferUpdate(server: LspServer, request: LanguageRequest): bool =
  var current: DocumentSnapshot
  let opened = server.openDocuments.tryFindDocument(request.uri, current)
  case request.kind
  of lrkOpen:
    not opened
  of lrkChange:
    opened and request.version > current.version
  of lrkClose:
    opened
  else:
    true

proc recordBufferUpdate(server: LspServer, request: LanguageRequest) =
  case request.kind
  of lrkOpen:
    discard server.openDocuments.openDocument(
      request.uri, request.text, request.version, request.positionEncoding
    )
  of lrkChange:
    discard server.openDocuments.updateDocument(
      request.uri, request.text, request.version, request.positionEncoding
    )
  of lrkClose:
    discard server.openDocuments.closeDocument(request.uri)
  else:
    return
  var keys: seq[string]
  for document in server.openDocuments.dirtyDocuments():
    keys.add(document.path & "\0" & $document.textHash)
  keys.sort()
  let identity =
    if keys.len == 0:
      0'u64
    else:
      stableTextHash(keys.join("\0"))
  if identity == server.overlayIdentity:
    return
  server.overlayIdentity = identity
  if not server.compilerEnabled:
    return
  inc server.compilerSourceGeneration
  server.compilerCancellation.cancelCompiler()
  if server.asynchronousSession:
    # Only the home loop advances this deadline. While waiting it polls in
    # short intervals; with no pending edit it blocks normally without spinning.
    server.refreshDeadline = getMonoTime().ticks + 200_000_000
  else:
    server.requestCompilerRefresh()

proc runCompilerRefreshSynchronously(server: LspServer) =
  if not server.compilerEnabled:
    return
  server.prepareCompilerRefresh()
  server.compilerLoading = true
  server.semanticLoading = true
  let cancellation = newCompilerCancellation()
  server.compilerCancellation = cancellation
  let completion = CompilerRefreshCompletion(
    result: runCompilerRefresh(
      CompilerRefreshRequest(
        workspace: server.workspace,
        capabilities: server.compiler,
        documentGeneration: server.documentGeneration,
        sourceGeneration: server.compilerSourceGeneration,
        cancellation: cancellation,
        previousHeads: server.reusableHeads(),
        overlays: server.openDocuments.dirtyDocuments(),
        forceRebuild: server.forceCompilerRefresh,
        priorityHead: server.headForDocument(server.activeDocument),
      ),
      proc(progress: CompilerHeadProgress) =
        server.receiveCompilerHeadProgress(progress),
    )
  )
  server.forceCompilerRefresh = false
  server.receiveCompilerRefreshCompletion(completion)

proc currentLanguageStamp(server: LspServer): LanguageStamp =
  LanguageStamp(
    valid: true,
    projectId: server.workspace.projectId,
    documentGeneration: server.documentGeneration,
    sourceGeneration: server.compilerSourceGeneration,
    configurationGeneration: server.workspace.configurationGeneration,
    configurationFingerprint: server.workspace.configurationFingerprint,
    compilerFingerprint: if server.compilerEnabled: server.compiler.fingerprint else: 0,
  )

proc stampMatches(a, b: LanguageStamp): bool =
  a.valid == b.valid and (
    not a.valid or (
      (a.projectId.len == 0 or b.projectId.len == 0 or a.projectId == b.projectId) and
      a.documentGeneration == b.documentGeneration and
      a.sourceGeneration == b.sourceGeneration and
      a.configurationGeneration == b.configurationGeneration and
      a.configurationFingerprint == b.configurationFingerprint and
      a.compilerFingerprint == b.compilerFingerprint
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
  of lrkDefinition:
    result = newJArray()
    for symbol in response.symbols:
      result.add(symbol.lspSymbolInformation()["location"])
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

  var awaitingHead = false
  var missingHead = false
  if hasResponse and server.compilerEnabled and
      kind in {lrkDocumentSymbols, lrkHover, lrkDefinition}:
    let path = pathFromDocumentUri(request.uri)
    let chosen = server.preferredHeads.getOrDefault(
      path, server.activeSnapshot.graph.preferredHead(path)
    )
    missingHead =
      not server.documentHasAnalysis(request.uri) or (
        server.openDocuments.containsDocument(request.uri) and
        (server.refreshDeadline > 0 or server.compilerRefreshPending)
      )
    if missingHead:
      awaitingHead =
        server.refreshDeadline > 0 or (
          server.compilerLoading and
          (chosen.len == 0 or chosen notin server.completedHeads)
        )
      if not awaitingHead:
        server.sendError(
          id, LspAnalysisUnavailable, "analysis unavailable for this document's head"
        )
        return false

  if hasResponse and
      kind in {lrkDocumentSymbols, lrkWorkspaceSymbols, lrkHover, lrkDefinition} and
      server.semanticCapabilities and (
    awaitingHead or (kind == lrkWorkspaceSymbols and server.compilerLoading) or
    (not server.semanticReady and not server.semanticFailed)
  ):
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
    of "textDocument/hover", "textDocument/definition":
      request = parseHoverRequest(params, server.positionEncoding)
      if methodName == "textDocument/definition":
        request.kind = lrkDefinition
    else:
      return

    debug "Processing LSP language operation",
      methodName = methodName,
      uri = request.uri,
      version = request.version,
      textBytes = request.text.len,
      query = request.query

    if not server.validBufferUpdate(request):
      debug "Ignoring stale or unordered buffer notification",
        uri = request.uri, version = request.version
      return
    var stamp = server.currentLanguageStamp()
    if request.kind in {lrkOpen, lrkChange, lrkClose}:
      inc stamp.documentGeneration
    let accepted = server.submitLanguageRequest(request, id, request.kind, stamp)
    if accepted and request.kind in {lrkOpen, lrkChange, lrkClose}:
      server.documentGeneration = stamp.documentGeneration
      server.recordBufferUpdate(request)
    if accepted and
        request.kind in {
          lrkOpen, lrkChange, lrkDocumentSymbols, lrkHover, lrkDefinition
        }:
      server.prioritizeDocument(request.uri)
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
  except CatchableError as error:
    warn "Received invalid JSON-RPC message", failure = error.msg
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
  debug "Received JSON-RPC message",
    methodName = methodName,
    requestId =
      if id.isNil:
        "notification"
      else:
        $id
  if methodName == "$/cancelRequest" and id.isNil:
    try:
      server.cancelClientRequest(parseCancelId(root.requestParams()))
    except CatchableError:
      discard
    return

  if methodName == "initialize":
    ## Keep the transport-independent Sigils route for direct adapter users,
    ## while preserving the prerequisite message on the asynchronous stdio
    ## path where Nimdex owns response dispatch.
    try:
      let value = server.initializeLsp(root.requestParams())
      if not id.isNil:
        server.dispatcher.sendJsonRpcMessage(successResponse(id, value))
    except RpcRouteError as error:
      if not id.isNil:
        server.sendError(id, error.code, error.msg)
    except CatchableError as error:
      if not id.isNil:
        server.sendError(id, RpcInternalError, error.msg)
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
      methodName == "textDocument/hover" or methodName == "textDocument/definition":
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
    info "Nimdex LSP input stream stopped", projectId = server.workspace.projectId

proc compilerStampMatches(server: LspServer, stamp: AnalysisStamp): bool =
  let current = server.currentLanguageStamp()
  stamp.valid and stamp.projectId == current.projectId and
    stamp.sourceGeneration == server.compilerSourceGeneration and
    stamp.configurationGeneration == current.configurationGeneration and
    stamp.configurationFingerprint == current.configurationFingerprint and
    stamp.compilerFingerprint == current.compilerFingerprint

proc drainQueuedLanguageRequests(
    server: LspServer, available: bool, errorMessage: string
) =
  if server.queued.len == 0:
    return
  let queued = move(server.queued)
  for item in queued:
    if not available:
      server.sendError(
        item.id,
        LspAnalysisUnavailable,
        "analysis unavailable: " & (
          if errorMessage.len > 0: errorMessage
          else: "compiler-backed analysis is unavailable"
        ),
      )
    else:
      discard server.submitLanguageRequest(item.request, item.id, item.kind, item.stamp)

proc receiveBifIndexCompletion(
    server: LspServer, completion: BifIndexCompletion
) {.slot.} =
  if server.isNil:
    return
  server.semanticLoading = false
  if completion.ok:
    info "Installing semantic index",
      projectId = server.workspace.projectId,
      moduleCount = completion.snapshot.moduleCount(),
      symbolCount = completion.snapshot.symbolCount(),
      tokenCount = completion.snapshot.tokenCount(),
      failureCount = completion.snapshot.failureCount()
    server.activeSnapshot = completion.snapshot
    server.language.installIndex(completion.snapshot)
    server.semanticReady = true
    server.semanticFailed = false
  else:
    server.semanticFailed = true
    warn "Semantic index failed",
      projectId = server.workspace.projectId, failure = completion.error

  server.stopSemanticIndex()
  server.drainQueuedLanguageRequests(
    completion.ok, if completion.ok: "" else: completion.error
  )

proc receiveCompilerHeadProgress(
    server: LspServer, progress: CompilerHeadProgress
) {.slot.} =
  if server.isNil or server.state != lssRunning or
      not server.compilerStampMatches(progress.stamp) or
      server.compilerCancellation.isCompilerCancelled():
    return
  server.completedHeads.add(progress.headPath)
  server.headDiagnostics[progress.headPath] = progress.diagnostics
  if progress.ok:
    server.progressHeads.add(progress.analysis)
    var replaced = false
    for head in server.compilerHeads.mitems:
      if head.headPath == progress.headPath:
        head = progress.analysis
        replaced = true
        break
    if not replaced:
      server.compilerHeads.add(progress.analysis)
    if not progress.reused:
      server.progressUsesPrevious = false
    if not server.progressUsesPrevious:
      if not server.progressSnapshotStarted:
        server.progressSnapshot = combinedHeadSnapshot(
          server.workspace, server.progressHeads, progress.stamp,
          server.refreshEntryPoints,
        )
        server.progressSnapshotStarted = true
      else:
        server.progressSnapshot.mergeHead(progress.analysis.snapshot[])
        server.progressSnapshot.sourceFingerprint =
          headSourceFingerprint(server.progressHeads)
        server.progressSnapshot.analysisStamp.sourceFingerprint =
          server.progressSnapshot.sourceFingerprint
      server.progressSnapshot.preferredHeads = server.preferredHeads
      server.activeSnapshot = server.progressSnapshot
      server.language.installIndex(server.activeSnapshot)
    server.semanticReady = true
    server.semanticFailed = false
  else:
    server.failedHeads.add(progress.headPath)
    server.progressUsesPrevious = false
  var diagnostics: seq[CompilerDiagnostic]
  for head in server.refreshEntryPoints:
    diagnostics.add(server.headDiagnostics.getOrDefault(head))
  server.publishCompilerDiagnostics(diagnostics)
  server.drainQueuedLanguageRequests(true, "")

proc receiveCompilerRefreshCompletion(
    server: LspServer, completion: CompilerRefreshCompletion
) {.slot.} =
  if server.isNil:
    return

  let refresh = completion.result
  let current = server.compilerStampMatches(refresh.stamp)
  let restart = server.compilerRefreshPending and not server.exitRequested
  if current:
    server.lastCompilerCachePath = refresh.cachePath
    server.lastCompilerCommands = refresh.commandLines
    server.lastCompilerArtifacts = refresh.artifactPaths
    server.lastCompilerExitCode = refresh.exitCode
    server.lastCompilerStdoutBytes = refresh.stdout.len
    server.lastCompilerStderrBytes = refresh.stderr.len
    server.lastCompilerError = refresh.error
    server.lastCompilerCancelled = refresh.cancelled
    server.lastCompiledHeads = refresh.compiledHeads
    server.lastReusedHeads = refresh.reusedHeads
    server.lastLoadedArtifacts = refresh.loadedArtifacts
    server.lastReusedArtifacts = refresh.reusedArtifacts
    server.lastRestoredHeads = refresh.restoredHeads
  server.compilerRefreshPending = false
  server.semanticLoading = false
  server.stopCompilerRefresh()

  if not current:
    debug "Discarding superseded compiler refresh",
      projectId = server.workspace.projectId,
      documentGeneration = refresh.stamp.documentGeneration,
      currentDocumentGeneration = server.documentGeneration
    if restart and server.state == lssRunning:
      server.startCompilerRefresh()
    return
  if refresh.cancelled:
    info "Compiler refresh was cancelled", projectId = server.workspace.projectId
    if restart and server.state == lssRunning:
      server.startCompilerRefresh()
    return

  server.publishCompilerDiagnostics(refresh.diagnostics)
  server.failedHeads = refresh.failedHeads
  server.completedHeads = server.refreshEntryPoints
  if refresh.stamp.valid:
    info "Installing compiler-backed semantic index",
      projectId = server.workspace.projectId,
      moduleCount = refresh.snapshot.moduleCount(),
      symbolCount = refresh.snapshot.symbolCount(),
      tokenCount = refresh.snapshot.tokenCount(),
      artifactCount = refresh.artifactPaths.len
    let unchanged =
      refresh.ok and server.progressUsesPrevious and
      server.activeSnapshot.sourceFingerprint == refresh.snapshot.sourceFingerprint
    if unchanged:
      server.activeSnapshot.analysisStamp = refresh.stamp
    else:
      server.activeSnapshot = refresh.snapshot
      server.activeSnapshot.preferredHeads = server.preferredHeads
      server.language.installIndex(server.activeSnapshot)
    server.compilerHeads = refresh.heads
    if server.openDocuments.dirtyDocuments().len == 0:
      server.savedHeads = refresh.heads
    server.progressSnapshot = SemanticSnapshot()
    server.progressHeads.setLen(0)
    server.semanticReady = refresh.heads.len > 0
    server.semanticFailed = not server.semanticReady
  if not refresh.ok:
    warn "Compiler refresh failed",
      projectId = server.workspace.projectId,
      compilerPath = refresh.compiler.compilerPath,
      exitCode = refresh.exitCode,
      cachePath = refresh.cachePath,
      failure = refresh.error
  server.drainQueuedLanguageRequests(server.semanticReady, refresh.error)

  if restart and server.state == lssRunning:
    server.startCompilerRefresh()

proc initializeLsp(server: LspServer, params: JsonNode): JsonNode =
  if server.state != lssCreated:
    raiseLspError(RpcInvalidRequest, "server has already been initialized")
  let initializeParams = requireObject(params, "initialize params")
  server.positionEncoding = negotiatePositionEncoding(params)
  let rootUri = rootUriFromInitialize(initializeParams)
  let compilerOptions = compilerOptionsFromInitialize(
    initializeParams, server.configuredCompilerPath, server.configuredCompilerFrontend
  )
  let configuredRoots =
    if server.artifactRoots.len > 0:
      server.artifactRoots
    else:
      artifactRootsFromInitialize(initializeParams)

  var compilerRequested = compilerOptions.configured
  if not compilerRequested and not compilerOptions.autoCompileSet and
      configuredRoots.len == 0 and rootUri.len > 0:
    ## A normal workspace with a discoverable Nim entry point uses the
    ## compiler-backed path by default. Artifact-only mode remains available
    ## for explicit phase-2 compatibility roots.
    let candidateWorkspace = initWorkspace(rootUri)
    compilerRequested = discoverCompilerEntryPoints(candidateWorkspace).len > 0

  let resolvedCompilerPath = resolveCompilerPath(rootUri, compilerOptions.compilerPath)
  var resolvedCacheRoot = ""
  if compilerOptions.cacheRoot.len > 0:
    resolvedCacheRoot = resolveWorkspacePaths(rootUri, @[compilerOptions.cacheRoot])[0]
  server.workspace = initWorkspace(
    rootUri,
    entryPoints = resolveWorkspacePaths(rootUri, compilerOptions.entryPoints),
    importPaths = resolveWorkspacePaths(rootUri, compilerOptions.importPaths),
    nimArguments = compilerOptions.nimArguments,
    artifactRoots = resolveArtifactRoots(rootUri, configuredRoots),
    compilerPath = resolvedCompilerPath,
    compilerFrontend = compilerOptions.compilerFrontend,
    cacheRoot = resolvedCacheRoot,
  )
  server.artifactRoots = server.workspace.artifactRoots
  server.refreshEntryPoints = server.workspace.discoverCompilerEntryPoints()
  server.savedHeads =
    server.savedHeads.filterIt(it.headPath in server.refreshEntryPoints)
  for source, head in compilerOptions.preferredHeads:
    let sourcePath = resolveWorkspacePaths(rootUri, @[source])[0]
    let headPath = resolveWorkspacePaths(rootUri, @[head])[0]
    if headPath notin server.refreshEntryPoints:
      raiseLspError(
        RpcInvalidParams,
        "preferredHeads must refer to a discovered or configured head: " & head,
      )
    server.preferredHeads[sourcePath] = headPath
  info "Initialized Nimdex workspace",
    rootUri = server.workspace.rootUri,
    workspaceRoot = server.workspace.rootPath,
    projectId = server.workspace.projectId,
    compilerRequested = compilerRequested,
    compilerPath = server.workspace.compilerPath,
    cacheRoot = server.workspace.cacheRoot,
    entryPoints = server.workspace.entryPoints,
    importPaths = server.workspace.importPaths,
    artifactRoots = server.workspace.artifactRoots,
    nimArgumentCount = server.workspace.nimArguments.len
  if compilerRequested:
    server.compiler = probeCompiler(server.workspace.compilerPath)
    let prerequisite =
      server.compiler.requireCompiler(server.workspace.compilerFrontend)
    if prerequisite.len > 0:
      warn "Nimdex cannot use the configured Nim compiler",
        compilerPath = server.compiler.compilerPath, failure = prerequisite
      raiseLspError(LspCompilerUnavailable, prerequisite)
    server.compilerEnabled = true
    info "Compiler-backed analysis enabled",
      compilerPath = server.compiler.compilerPath,
      compilerVersion = server.compiler.version,
      compilerRevision = server.compiler.revision,
      supportsGenBif = server.compiler.supportsGenBif
  else:
    server.compiler = CompilerCapabilities()
    server.compilerEnabled = false
  debug "Resolved Nim library paths", libraryPaths = server.compilerLibraryPaths()
  server.semanticCapabilities = server.compilerEnabled or server.artifactRoots.len > 0

  server.state = lssInitializing
  result = newJObject()
  let capabilities = newJObject()
  let textDocumentSync = newJObject()
  textDocumentSync["openClose"] = %true
  textDocumentSync["change"] = %1
  textDocumentSync["save"] = %true
  capabilities["textDocumentSync"] = textDocumentSync
  capabilities["positionEncoding"] = %server.positionEncoding.positionEncodingName()
  if server.semanticCapabilities:
    capabilities["documentSymbolProvider"] = %true
    capabilities["workspaceSymbolProvider"] = %true
    capabilities["hoverProvider"] = %true
    capabilities["definitionProvider"] = %true
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
  if server.compilerEnabled:
    if server.asynchronousSession:
      server.startCompilerRefresh()
    else:
      server.runCompilerRefreshSynchronously()
  elif server.asynchronousSession:
    server.startSemanticIndex()
  else:
    server.installSemanticIndex()
  newJNull()

proc shutdownLsp(server: LspServer, params: JsonNode): JsonNode =
  discard params
  server.requireRunning()
  server.cancelQueuedLanguageWork()
  server.state = lssShuttingDown
  server.refreshDeadline = 0
  server.compilerRefreshPending = false
  server.compilerCancellation.cancelCompiler()
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
  let request = parseOpenRequest(params, server.positionEncoding)
  let response = server.language.request(request)
  requireLanguageSuccess(response)
  inc server.documentGeneration
  server.recordBufferUpdate(request)
  server.prioritizeDocument(
    requireString(params["textDocument"], "uri", "didOpen textDocument")
  )
  newJNull()

proc didChangeLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let request = parseChangeRequest(params, server.positionEncoding)
  let response = server.language.request(request)
  requireLanguageSuccess(response)
  inc server.documentGeneration
  server.recordBufferUpdate(request)
  newJNull()

proc noticeDiskChange(server: LspServer, uri: string) =
  let path = pathFromDocumentUri(uri)
  var known = false
  for head in server.compilerHeads:
    if path in head.inputPaths:
      known = true
      break
  if not known:
    # New import targets and external compile-time inputs have no old graph
    # edge. A client-reported change to one conservatively rebuilds all heads.
    server.forceCompilerRefresh = true

proc didSaveLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let document = requireObject(
    requireMember(
      requireObject(params, "didSave params"), "textDocument", "didSave params"
    ),
    "didSave textDocument",
  )
  server.noticeDiskChange(requireString(document, "uri", "didSave textDocument"))
  inc server.compilerSourceGeneration
  server.requestCompilerRefresh()
  newJNull()

proc didChangeWatchedFilesLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let changes = requireMember(
    requireObject(params, "didChangeWatchedFiles params"),
    "changes",
    "didChangeWatchedFiles params",
  )
  if changes.kind != JArray:
    raiseLspError(RpcInvalidParams, "didChangeWatchedFiles changes must be an array")
  for change in changes:
    let item = requireObject(change, "file change")
    let uri = requireString(item, "uri", "file change")
    let kind = requireInt(item, "type", "file change")
    if kind notin 1 .. 3:
      raiseLspError(RpcInvalidParams, "file change type must be 1, 2, or 3")
    server.noticeDiskChange(uri)
  if changes.len > 0:
    inc server.compilerSourceGeneration
    server.requestCompilerRefresh()
  newJNull()

proc didCloseLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let request = parseCloseRequest(params)
  let response = server.language.request(request)
  requireLanguageSuccess(response)
  inc server.documentGeneration
  server.recordBufferUpdate(request)
  newJNull()

proc documentSymbolsLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let request = parseDocumentSymbolsRequest(params, server.positionEncoding)
  if server.compilerEnabled and not server.documentHasAnalysis(request.uri):
    raiseLspError(
      LspAnalysisUnavailable, "analysis unavailable for this document's head"
    )
  server.prioritizeDocument(request.uri)
  let response = server.language.request(request)
  requireLanguageSuccess(response)
  result = newJArray()
  for symbol in response.symbols:
    result.add(symbol.lspSymbolInformation())

proc workspaceSymbolsLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  if server.compilerEnabled and not server.semanticReady:
    raiseLspError(LspAnalysisUnavailable, "analysis unavailable: no healthy heads")
  let response = server.language.request(
    parseWorkspaceSymbolsRequest(params, server.positionEncoding)
  )
  requireLanguageSuccess(response)
  result = newJArray()
  for symbol in response.symbols:
    result.add(symbol.lspSymbolInformation())

proc hoverLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  let request = parseHoverRequest(params, server.positionEncoding)
  if server.compilerEnabled and not server.documentHasAnalysis(request.uri):
    raiseLspError(
      LspAnalysisUnavailable, "analysis unavailable for this document's head"
    )
  server.prioritizeDocument(request.uri)
  let response = server.language.request(request)
  requireLanguageSuccess(response)
  if not response.found:
    return newJNull()

  let contents = newJObject()
  contents["kind"] = %"markdown"
  contents["value"] = %response.preview
  result = newJObject()
  result["contents"] = contents
  result["range"] = response.symbols[0].lspRange()

proc definitionLsp(server: LspServer, params: JsonNode): JsonNode =
  server.requireRunning()
  var request = parseHoverRequest(params, server.positionEncoding)
  request.kind = lrkDefinition
  if server.compilerEnabled and not server.documentHasAnalysis(request.uri):
    raiseLspError(
      LspAnalysisUnavailable, "analysis unavailable for this document's head"
    )
  server.prioritizeDocument(request.uri)
  let response = server.language.request(request)
  requireLanguageSuccess(response)
  languageResult(lrkDefinition, response)

proc registerLspRoutes(server: LspServer) =
  discard server.addMethod(initializeSelector, toDynamicMethod(initializeLsp))
  discard server.addMethod(initializedSelector, toDynamicMethod(initializedLsp))
  discard server.addMethod(shutdownSelector, toDynamicMethod(shutdownLsp))
  discard server.addMethod(exitSelector, toDynamicMethod(exitLsp))
  discard server.addMethod(didOpenSelector, toDynamicMethod(didOpenLsp))
  discard server.addMethod(didChangeSelector, toDynamicMethod(didChangeLsp))
  discard server.addMethod(didCloseSelector, toDynamicMethod(didCloseLsp))
  discard server.addMethod(didSaveSelector, toDynamicMethod(didSaveLsp))
  discard server.addMethod(
    didChangeWatchedFilesSelector, toDynamicMethod(didChangeWatchedFilesLsp)
  )
  discard server.addMethod(documentSymbolSelector, toDynamicMethod(documentSymbolsLsp))
  discard
    server.addMethod(workspaceSymbolSelector, toDynamicMethod(workspaceSymbolsLsp))
  discard server.addMethod(definitionSelector, toDynamicMethod(definitionLsp))
  discard server.addMethod(hoverSelector, toDynamicMethod(hoverLsp))
  discard server.addMethod(debugSelector, toDynamicMethod(debugLsp))

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
  server.adapter.registerSelectorMethod("textDocument/didSave", server, didSaveSelector)
  server.adapter.registerSelectorMethod(
    "workspace/didChangeWatchedFiles", server, didChangeWatchedFilesSelector
  )
  server.adapter.registerSelectorMethod(
    "textDocument/documentSymbol", server, documentSymbolSelector
  )
  server.adapter.registerSelectorMethod(
    "workspace/symbol", server, workspaceSymbolSelector
  )
  server.adapter.registerSelectorMethod(
    "textDocument/definition", server, definitionSelector
  )
  server.adapter.registerSelectorMethod("textDocument/hover", server, hoverSelector)
  server.adapter.registerSelectorMethod(LspDebugMethod, server, debugSelector)

proc newNimdexLspServer*(
    workers = 1,
    artifactRoots: seq[string] = @[],
    compilerPath = "",
    compilerFrontend = cfCompile,
): LspServer =
  ## Create an LSP server with worker-owned document state.
  startLocalThreadDefault()
  result = LspServer(
    adapter: newJsonRpcAdapter(),
    language: newLanguageRuntime(workers),
    home: getCurrentSigilThread(),
    artifactRoots: artifactRoots,
    configuredCompilerPath: compilerPath,
    configuredCompilerFrontend: compilerFrontend,
    state: lssCreated,
    exitStatus: LspExitSuccess,
    pending: initTable[LanguageWorkId, LspPendingRequest](),
    pendingByClientId: initTable[string, seq[LanguageWorkId]](),
    publishedDiagnosticUris: initTable[string, bool](),
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
    server.stopCompilerRefresh()
    server.language.close()
    server.reapWorkers()
    server.compilerHeads.setLen(0)
    server.savedHeads.setLen(0)
    server.progressHeads.setLen(0)
    server.activeSnapshot = SemanticSnapshot()
    server.progressSnapshot = SemanticSnapshot()
    server.openDocuments = DocumentStore()

proc writeLspResponse(server: LspServer, response: JsonRpcResponse) {.slot.} =
  server.writer.queueResponse(boundedLspResponse(response))

proc connectStdioReader(
    server: LspServer,
    dispatcher: JsonRpcDispatcher,
    readerProxy: AgentProxy[NimdexLspStdioReader],
) =
  connect(dispatcher, jsonRpcResponseReady, server, writeLspResponse(LspServer))
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

proc runNimdexLspStdio*(
    input: File = stdin,
    output: File = stdout,
    workers = 1,
    artifactRoots: seq[string] = @[],
    compilerPath = "",
    compilerFrontend = cfCompile,
): int =
  ## Serve LSP Content-Length messages until EOF or an exit notification.
  ##
  ## Input and output deliberately have different owners: the reader actor can
  ## block in File.readChar while the home thread continues to dispatch worker
  ## completions and flush framed responses.
  info "Starting Nimdex LSP server",
    compilerPath = compilerPath, artifactRoots = artifactRoots, workers = workers
  let server =
    newNimdexLspServer(workers, artifactRoots, compilerPath, compilerFrontend)
  server.asynchronousSession = true
  let dispatcher = newJsonRpcDispatcher(server.adapter)
  server.dispatcher = dispatcher
  let writer = jrStdio.newJsonRpcStdioIo(input, output, DefaultNimdexMessageSize)
  server.writer = writer
  let readerThread = newSigilThread()
  var reader = newNimdexLspStdioReader(input)
  var readerProxy = reader.moveToThread(readerThread)

  server.connectStdioReader(dispatcher, readerProxy)

  writer.startIo()
  readerThread.start()
  emit dispatcher.jsonRpcStartRequested()

  try:
    while true:
      let processed = server.home.pollAll(NonBlocking)
      server.finishLanguageWork()
      server.reapWorkers()
      if server.isExitRequested():
        if server.pending.len == 0 and server.queued.len == 0 and
            server.language.pendingCount() == 0:
          break
      elif server.inputStopped:
        server.exitStatus = LspExitFailure
        server.cancelAllLanguageWork()
        break
      if server.refreshDeadline > 0:
        if getMonoTime().ticks >= server.refreshDeadline:
          server.requestCompilerRefresh()
        elif processed == 0:
          sleep(10)
      elif processed == 0:
        discard server.home.poll(Blocking)
  finally:
    if not readerThread.isNil:
      readerThread.send(ThreadSignal(kind: Exit))
      readerThread.join()
      readerProxy = nil
      doAssert readerThread.disposeJoined()
    server.close()
    server.reapWorkers()
    writer.stopIo()
    info "Nimdex LSP server stopped", exitStatus = server.exitStatus()

  server.exitStatus()
