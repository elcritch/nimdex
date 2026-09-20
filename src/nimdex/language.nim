## Worker-pool language components used by the Nimdex LSP server.

import std/[os, strutils, tables, times]

import ./documents
import ./semantic

import sigils

type
  LanguageRequestKind* = enum ## Operations supported by the language component.
    lrkOpen ## Store a newly opened document.
    lrkChange ## Replace an open document's full text.
    lrkClose ## Remove a document from the worker state.
    lrkDocumentSymbols ## Query declarations for one source document.
    lrkWorkspaceSymbols ## Search declarations across indexed modules.
    lrkHover ## Query compiler-backed hover information when available.

  LanguageSymbol* = object ## A verified semantic symbol and its source range.
    symbol*: SymbolInfo ## The owned compiler-backed symbol record.
    start*: TextPosition ## Inclusive LSP position of the symbol name.
    finish*: TextPosition ## Exclusive LSP position of the symbol name.

  LanguageRequest* = object ## A language operation sent to worker-owned state.
    kind*: LanguageRequestKind ## The operation to perform.
    uri*: string ## The LSP document URI.
    version*: int ## The document version supplied by the client.
    text*: string ## Full document text for open and change operations.
    query*: string ## Workspace symbol query text.
    line*: int ## Zero-based line for a hover query.
    character*: int ## Zero-based character for a hover query.
    positionEncoding*: PositionEncoding ## Client character-unit encoding.

  LanguageResponse* = object
    ## The deterministic result returned by worker-owned language state.
    ok*: bool ## Whether the operation completed successfully.
    found*: bool ## Whether the query found at least one verified result.
    uri*: string ## The URI associated with the operation.
    version*: int ## The current document version for a successful query.
    preview*: string ## Hover text when compiler-backed analysis is available.
    symbols*: seq[LanguageSymbol] ## Owned symbols returned by an indexed query.
    error*: string ## A diagnostic description when `ok` is false.

  LanguageSource = ref object of AgentActor

  LanguageService = ref object of AgentActor
    documents: DocumentStore
    semantic: SemanticSnapshot
    hasSemantic: bool

  LanguageReply = ref object of AgentActor
    responseReady: bool
    response: LanguageResponse

  LanguageRuntime* = ref object ## Main-thread bridge to worker-owned language state.
    home: SigilThreadPtr
    pool: SigilThreadPoolPtr
    source: LanguageSource
    reply: LanguageReply
    serviceProxy: AgentProxy[LanguageService]
    closed: bool

proc languageRequest(source: LanguageSource, request: LanguageRequest) {.signal.}
proc languageResponse(source: LanguageService, response: LanguageResponse) {.signal.}
proc semanticSnapshotReady(
  source: LanguageSource, snapshot: sink SemanticSnapshot
) {.signal.}

proc sourceDocumentFor(
    self: LanguageService,
    location: SourceLocation,
    positionEncoding: PositionEncoding,
    document: var DocumentSnapshot,
): bool =
  if not location.valid or location.sourceTextHash == 0:
    return false

  if location.path.len > 0:
    if not fileExists(location.path):
      return false
    if location.artifactModifiedUnix > 0:
      try:
        if int64(getLastModificationTime(location.path).toUnixFloat() * 1_000_000_000.0) >
            location.artifactModifiedUnix:
          return false
      except CatchableError:
        return false

  var overlay: DocumentSnapshot
  if self.documents.tryFindDocument(location.uri, overlay):
    if overlay.textHash != location.sourceTextHash:
      return false
    document = initDocumentSnapshot(
      location.uri, overlay.content, overlay.version, positionEncoding
    )
    return true

  if location.path.len == 0:
    return false
  try:
    let content = readFile(location.path)
    if stableTextHash(content) != location.sourceTextHash:
      return false
    document = initDocumentSnapshot(location.uri, content, 0, positionEncoding)
    true
  except CatchableError:
    false

proc moduleIsCurrent(self: LanguageService, module: ModuleSnapshot): bool =
  if module.sourceTextHash == 0:
    return false
  let location = SourceLocation(
    valid: true,
    uri: module.sourceUri,
    path: module.sourcePath,
    sourceTextHash: module.sourceTextHash,
    artifactModifiedUnix: module.artifactModifiedUnix,
  )
  var document: DocumentSnapshot
  self.sourceDocumentFor(location, peUtf16, document)

proc cachedSourceDocumentFor(
    self: LanguageService,
    location: SourceLocation,
    positionEncoding: PositionEncoding,
    cache: var Table[string, DocumentSnapshot],
    document: var DocumentSnapshot,
): bool =
  let key =
    location.uri & "\0" & $location.sourceTextHash & "\0" &
    $location.artifactModifiedUnix & "\0" & $positionEncoding
  if key in cache:
    document = cache[key]
    return true
  if not self.sourceDocumentFor(location, positionEncoding, document):
    return false
  cache[key] = document
  true

proc symbolSpan(
    self: LanguageService,
    symbol: SymbolInfo,
    positionEncoding: PositionEncoding,
    cache: var Table[string, DocumentSnapshot],
    document: var DocumentSnapshot,
    startOffset, finishOffset: var int,
): bool =
  if not self.cachedSourceDocumentFor(
    symbol.location, positionEncoding, cache, document
  ):
    return false
  document.tryTokenSpanAt(
    symbol.location.line, symbol.location.column, symbol.name, startOffset, finishOffset
  )

proc symbolMatchesQuery(symbol: SymbolInfo, query: string): bool =
  let needle = query.toLowerAscii()
  needle.len == 0 or symbol.name.toLowerAscii().contains(needle) or
    symbol.qualifiedName.toLowerAscii().contains(needle)

proc addLanguageSymbol(
    response: var LanguageResponse,
    symbol: SymbolInfo,
    document: DocumentSnapshot,
    startOffset, finishOffset: int,
): bool =
  var start, finish: TextPosition
  if not document.tryPositionAt(startOffset, start):
    return false
  if not document.tryPositionAt(finishOffset, finish):
    return false
  response.symbols.add(LanguageSymbol(symbol: symbol, start: start, finish: finish))
  true

proc addDocumentSymbols(
    self: LanguageService,
    uri: string,
    positionEncoding: PositionEncoding,
    response: var LanguageResponse,
) =
  if not self.hasSemantic:
    response.ok = false
    response.error =
      "analysis unavailable: compiler-backed semantic snapshot is not installed"
    return
  var sourceDocuments = initTable[string, DocumentSnapshot]()
  for module in self.semantic.modules:
    if module.sourceUri != uri or not self.moduleIsCurrent(module):
      continue
    for symbol in module.symbols:
      if symbol.location.uri != uri or not symbol.location.valid:
        continue
      var document: DocumentSnapshot
      var startOffset, finishOffset: int
      if self.symbolSpan(
        symbol, positionEncoding, sourceDocuments, document, startOffset, finishOffset
      ):
        discard response.addLanguageSymbol(symbol, document, startOffset, finishOffset)
  response.found = response.symbols.len > 0

proc addWorkspaceSymbols(
    self: LanguageService,
    query: string,
    positionEncoding: PositionEncoding,
    response: var LanguageResponse,
) =
  if not self.hasSemantic:
    response.ok = false
    response.error =
      "analysis unavailable: compiler-backed semantic snapshot is not installed"
    return
  var sourceDocuments = initTable[string, DocumentSnapshot]()
  for module in self.semantic.modules:
    if not self.moduleIsCurrent(module):
      continue
    for symbol in module.symbols:
      if not symbol.location.valid or not symbol.symbolMatchesQuery(query):
        continue
      var document: DocumentSnapshot
      var startOffset, finishOffset: int
      if self.symbolSpan(
        symbol, positionEncoding, sourceDocuments, document, startOffset, finishOffset
      ):
        discard response.addLanguageSymbol(symbol, document, startOffset, finishOffset)
  response.found = response.symbols.len > 0

proc findHoverSymbol(
    self: LanguageService, request: LanguageRequest, response: var LanguageResponse
) =
  if not self.hasSemantic:
    response.ok = false
    response.error =
      "analysis unavailable: compiler-backed semantic snapshot is not installed"
    return
  let position = TextPosition(line: request.line, character: request.character)
  var sourceDocuments = initTable[string, DocumentSnapshot]()
  for module in self.semantic.modules:
    if not self.moduleIsCurrent(module):
      continue
    for symbol in module.symbols:
      if not symbol.location.valid or symbol.location.uri != response.uri:
        continue
      var document: DocumentSnapshot
      var startOffset, finishOffset: int
      if not self.symbolSpan(
        symbol, request.positionEncoding, sourceDocuments, document, startOffset,
        finishOffset,
      ):
        continue
      var offset: int
      if not document.tryOffsetAt(position, offset):
        continue
      if offset >= startOffset and offset < finishOffset:
        response.found = true
        response.version = document.version
        if not response.addLanguageSymbol(symbol, document, startOffset, finishOffset):
          response.found = false
          return
        response.preview =
          "**" & symbol.name & "**\n\n`" & symbol.kind & "` `" & symbol.qualifiedName &
          "`"
        return

proc installSemanticSnapshot(
    self: LanguageService, snapshot: sink SemanticSnapshot
) {.slot.} =
  self.semantic = snapshot
  self.hasSemantic = true

proc processLanguageRequest(self: LanguageService, request: LanguageRequest) {.slot.} =
  var response = LanguageResponse(ok: true, uri: request.uri, version: request.version)
  try:
    response.uri = normalizeDocumentUri(request.uri)
    case request.kind
    of lrkOpen:
      case self.documents.openDocument(
        request.uri, request.text, request.version, request.positionEncoding
      )
      of dusApplied:
        discard
      of dusAlreadyOpen:
        response.ok = false
        response.error = "document is already open"
      of dusMissing, dusIgnoredStale:
        response.ok = false
        response.error = "document could not be opened"
    of lrkChange:
      case self.documents.updateDocument(
        request.uri, request.text, request.version, request.positionEncoding
      )
      of dusApplied:
        discard
      of dusMissing:
        response.ok = false
        response.error = "document is not open"
      of dusIgnoredStale:
        response.ok = false
        response.error = "document version is not newer than the open version"
      of dusAlreadyOpen:
        response.ok = false
        response.error = "document change was not applied"
    of lrkClose:
      discard self.documents.closeDocument(request.uri)
    of lrkDocumentSymbols:
      self.addDocumentSymbols(response.uri, request.positionEncoding, response)
    of lrkWorkspaceSymbols:
      self.addWorkspaceSymbols(request.query, request.positionEncoding, response)
    of lrkHover:
      self.findHoverSymbol(request, response)
  except CatchableError as error:
    response.ok = false
    response.error = "language state error: " & error.msg

  emit self.languageResponse(response)

proc receiveLanguageResponse(self: LanguageReply, response: LanguageResponse) {.slot.} =
  self.response = response
  self.responseReady = true

proc newLanguageRuntime*(workers = 1): LanguageRuntime =
  ## Start a Sigils worker pool and attach one serialized document-state actor.
  startLocalThreadDefault()
  let pool = newSigilThreadPool(workers = workers)
  pool.start()

  var service = LanguageService(documents: initDocumentStore())
  let serviceProxy = service.moveToThread(pool)
  result = LanguageRuntime(
    home: getCurrentSigilThread(),
    pool: pool,
    source: LanguageSource(),
    reply: LanguageReply(),
    serviceProxy: serviceProxy,
  )

  connectThreaded(
    result.source, languageRequest, result.serviceProxy, processLanguageRequest
  )
  connectThreaded(
    result.serviceProxy,
    languageResponse,
    result.reply,
    receiveLanguageResponse(LanguageReply),
  )

  connectThreaded(
    result.source,
    semanticSnapshotReady,
    result.serviceProxy,
    installSemanticSnapshot(LanguageService),
  )

proc installIndex*(runtime: LanguageRuntime, snapshot: sink SemanticSnapshot) =
  ## Install a complete owned semantic snapshot before serving indexed queries.
  if runtime.isNil or runtime.closed:
    return
  emit runtime.source.semanticSnapshotReady(snapshot)

proc request*(runtime: LanguageRuntime, request: LanguageRequest): LanguageResponse =
  ## Run one language operation and wait while pumping the caller's scheduler.
  if runtime.isNil or runtime.closed:
    return LanguageResponse(ok: false, error: "language runtime is closed")

  runtime.reply.responseReady = false
  emit runtime.source.languageRequest(request)
  while not runtime.reply.responseReady:
    discard runtime.home.poll(Blocking)
  runtime.reply.response

proc close*(runtime: LanguageRuntime) =
  ## Stop the language worker pool after all submitted operations have settled.
  if runtime.isNil or runtime.closed:
    return
  runtime.closed = true
  runtime.serviceProxy = nil
  runtime.pool.stop()
  runtime.pool.join()
