## Worker-pool language components used by the Nimdex LSP server.

import std/[atomics, os, sets, sha1, strutils, tables]

import ./workerlife

import ./documents
import ./semantic
import ./binnycompat

import sigils

type
  LanguageWorkId* = uint64 ## Internal identity for one submitted operation.

  LanguageStamp* = AnalysisStamp ## Version of the ordered language state used by work.

  LanguageRequestKind* = enum ## Operations supported by the language component.
    lrkOpen ## Store a newly opened document.
    lrkChange ## Replace an open document's full text.
    lrkClose ## Remove a document from the worker state.
    lrkDocumentSymbols ## Query declarations for one source document.
    lrkWorkspaceSymbols ## Search declarations across indexed modules.
    lrkDefinition ## Resolve a verified use to its compiler declaration.
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
    stamp*: LanguageStamp ## Expected ordered state for query operations.

  LanguageResponse* = object
    ## The deterministic result returned by worker-owned language state.
    ok*: bool ## Whether the operation completed successfully.
    found*: bool ## Whether the query found at least one verified result.
    uri*: string ## The URI associated with the operation.
    version*: int ## The current document version for a successful query.
    preview*: string ## Hover text when compiler-backed analysis is available.
    symbols*: seq[LanguageSymbol] ## Owned symbols returned by an indexed query.
    error*: string ## A diagnostic description when `ok` is false.
    cancelled*: bool ## Whether the operation stopped at a cancellation checkpoint.
    superseded*: bool ## Whether the request's state stamp was no longer current.
    stamp*: LanguageStamp ## State stamp at the point of completion.

  LanguageCancellation = object
    cancelled: Atomic[bool]

  LanguageWork = object
    id: LanguageWorkId
    request: LanguageRequest
    cancellation: ptr LanguageCancellation

  LanguageCompletion* = object
    id*: LanguageWorkId
    response*: LanguageResponse

  LanguageSource = ref object of AgentActor

  OccurrenceCache = ref object
    artifactHash, uri: string
    values: seq[BinnyOccurrence]

  LanguageService = ref object of AgentActor
    documents: DocumentStore
    semantic: SemanticSnapshot
    hasSemantic: bool
    occurrences: seq[OccurrenceCache]
    documentGeneration: uint64
    configurationGeneration: uint64
    configurationFingerprint: uint64
    compilerFingerprint: uint64

  LanguageReply = ref object of AgentActor
    completions: seq[LanguageCompletion]

  LanguageRuntime* = ref object ## Main-thread bridge to worker-owned language state.
    home: SigilThreadPtr
    pool: SigilThreadPoolPtr
    source: LanguageSource
    reply: LanguageReply
    serviceProxy: AgentProxy[LanguageService]
    nextWorkId: LanguageWorkId
    pending: Table[LanguageWorkId, ptr LanguageCancellation]
    retired: Table[LanguageWorkId, ptr LanguageCancellation]
    maxPending: int
    closed: bool

proc languageWork(source: LanguageSource, work: sink LanguageWork) {.signal.}
proc languageResponse(
  source: LanguageService, completion: sink LanguageCompletion
) {.signal.}

proc semanticSnapshotReady(
  source: LanguageSource, snapshot: sink SemanticSnapshot
) {.signal.}

proc newLanguageCancellation(): ptr LanguageCancellation =
  result = cast[ptr LanguageCancellation](allocShared0(sizeof(LanguageCancellation)))
  result[].cancelled.store(false, moRelaxed)

proc isCancelled(cancellation: ptr LanguageCancellation): bool =
  not cancellation.isNil and cancellation.cancelled.load(moAcquire)

proc cancelledResponse(
    work: LanguageWork, stamp: LanguageStamp = LanguageStamp()
): LanguageCompletion =
  LanguageCompletion(
    id: work.id,
    response: LanguageResponse(
      ok: false, cancelled: true, error: "language request was cancelled", stamp: stamp
    ),
  )

proc markCancelled(cancellation: ptr LanguageCancellation) =
  if not cancellation.isNil:
    cancellation.cancelled.store(true, moRelease)

proc releaseCancellation(cancellation: ptr LanguageCancellation) =
  if not cancellation.isNil:
    deallocShared(cancellation)

proc sourceDocumentFor(
    self: LanguageService,
    location: SourceLocation,
    positionEncoding: PositionEncoding,
    document: var DocumentSnapshot,
): bool =
  if not location.valid or location.sourceTextHash == 0:
    return false

  var overlay: DocumentSnapshot
  if self.documents.tryFindDocument(location.uri, overlay):
    if overlay.textHash != location.sourceTextHash:
      return false
    document = initDocumentSnapshot(
      location.uri, overlay.content, overlay.version, positionEncoding
    )
    return true

  if location.path.len > 0:
    if not fileExists(location.path):
      return false

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

proc moduleIsCurrent(
    self: LanguageService, module: ModuleSnapshot, chosenHead = ""
): bool =
  let head =
    if chosenHead.len > 0:
      chosenHead
    else:
      self.semantic.preferredHeads.getOrDefault(
        module.sourcePath, self.semantic.graph.preferredHead(module.sourcePath)
      )
  if head.len > 0 and head notin module.headFiles:
    return false
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
    cancellation: ptr LanguageCancellation,
) =
  if not self.hasSemantic:
    response.ok = false
    response.error =
      "analysis unavailable: compiler-backed semantic snapshot is not installed"
    return
  var sourceDocuments = initTable[string, DocumentSnapshot]()
  var seen = initHashSet[string]()
  for module in self.semantic.modules:
    if cancellation.isCancelled():
      response.ok = false
      response.cancelled = true
      response.error = "language request was cancelled"
      return
    if module.sourceUri != uri or not self.moduleIsCurrent(module):
      continue
    for symbol in module.symbols:
      if cancellation.isCancelled():
        response.ok = false
        response.cancelled = true
        response.error = "language request was cancelled"
        return
      if symbol.location.uri != uri or not symbol.location.valid or symbol.key in seen:
        continue
      var document: DocumentSnapshot
      var startOffset, finishOffset: int
      if self.symbolSpan(
        symbol, positionEncoding, sourceDocuments, document, startOffset, finishOffset
      ):
        if response.addLanguageSymbol(symbol, document, startOffset, finishOffset):
          seen.incl(symbol.key)
  response.found = response.symbols.len > 0

proc addWorkspaceSymbols(
    self: LanguageService,
    query: string,
    positionEncoding: PositionEncoding,
    response: var LanguageResponse,
    cancellation: ptr LanguageCancellation,
) =
  if not self.hasSemantic:
    response.ok = false
    response.error =
      "analysis unavailable: compiler-backed semantic snapshot is not installed"
    return
  var sourceDocuments = initTable[string, DocumentSnapshot]()
  var seen = initHashSet[string]()
  for module in self.semantic.modules:
    if cancellation.isCancelled():
      response.ok = false
      response.cancelled = true
      response.error = "language request was cancelled"
      return
    if not self.moduleIsCurrent(module):
      continue
    for symbol in module.symbols:
      if cancellation.isCancelled():
        response.ok = false
        response.cancelled = true
        response.error = "language request was cancelled"
        return
      if not symbol.location.valid or not symbol.symbolMatchesQuery(query) or
          symbol.key in seen:
        continue
      var document: DocumentSnapshot
      var startOffset, finishOffset: int
      if self.symbolSpan(
        symbol, positionEncoding, sourceDocuments, document, startOffset, finishOffset
      ):
        if response.addLanguageSymbol(symbol, document, startOffset, finishOffset):
          seen.incl(symbol.key)
  response.found = response.symbols.len > 0

proc occurrencesFor(
    self: LanguageService, module: ModuleSnapshot, uri, sourcePath: string
): OccurrenceCache =
  for i, entry in self.occurrences:
    if entry.artifactHash == module.artifactHash and entry.uri == uri:
      let recent = entry
      self.occurrences.delete(i)
      self.occurrences.add(recent)
      return recent
  # The compiler may already be replacing a cache. Never pair newer uses with
  # an older declaration snapshot. Persistence alone does not validate a BIF.
  try:
    if module.artifactHash.len == 0 or not fileExists(module.artifactPath) or
        $secureHashFile(module.artifactPath) != module.artifactHash:
      return OccurrenceCache()
    result = OccurrenceCache(
      artifactHash: module.artifactHash,
      uri: uri,
      values: readBinnyOccurrences(module.artifactPath, sourcePath),
    )
    if $secureHashFile(module.artifactPath) != module.artifactHash:
      return OccurrenceCache()
  except CatchableError:
    return OccurrenceCache()
  if self.occurrences.len >= 4:
    self.occurrences.delete(0)
  self.occurrences.add(result)

proc findPositionSymbol(
    self: LanguageService,
    request: LanguageRequest,
    response: var LanguageResponse,
    cancellation: ptr LanguageCancellation,
) =
  if not self.hasSemantic:
    response.ok = false
    response.error =
      "analysis unavailable: compiler-backed semantic snapshot is not installed"
    return
  let position = TextPosition(line: request.line, character: request.character)
  var sourceDocuments = initTable[string, DocumentSnapshot]()
  let sourcePath = pathFromDocumentUri(response.uri)
  let head = self.semantic.preferredHeads.getOrDefault(
    sourcePath, self.semantic.graph.preferredHead(sourcePath)
  )
  var targets: seq[SymbolInfo]
  var useSymbol: SymbolInfo
  var useDocument: DocumentSnapshot
  var useStart, useFinish: int
  for module in self.semantic.modules:
    if cancellation.isCancelled():
      response.ok = false
      response.cancelled = true
      response.error = "language request was cancelled"
      return
    if head.len > 0 and head notin module.headFiles:
      continue
    if module.sourceUri != response.uri and sourcePath notin module.includes:
      continue
    if not self.moduleIsCurrent(module, head):
      continue
    # Declaration hover/definition also works after artifacts have been evicted.
    for symbol in module.symbols:
      if symbol.instantiatedFrom.len > 0 or symbol.location.uri != response.uri or
          symbol.location.line != request.line + 1:
        continue
      var document: DocumentSnapshot
      var startOffset, finishOffset, offset: int
      if self.symbolSpan(
        symbol, request.positionEncoding, sourceDocuments, document, startOffset,
        finishOffset,
      ) and document.tryOffsetAt(position, offset) and offset >= startOffset and
          offset < finishOffset:
        targets = @[symbol]
        useSymbol = symbol
        useDocument = document
        useStart = startOffset
        useFinish = finishOffset
        break
    if targets.len > 0:
      break
    for occurrence in self.occurrencesFor(module, response.uri, sourcePath).values:
      if occurrence.location.line != request.line + 1:
        continue
      var candidates = self.semantic.findSymbols(
        occurrence.name,
        head,
        (if occurrence.name.count('.') < 2: module.sourcePath else: ""),
      )
      for symbol in candidates:
        var querySymbol = symbol
        querySymbol.location = SourceLocation(
          valid: true,
          uri: response.uri,
          path: sourcePath,
          sourceTextHash: module.sourceTextHash,
          artifactModifiedUnix: module.artifactModifiedUnix,
          line: occurrence.location.line,
          column: occurrence.location.column,
        )
        # Includes have their own content hash, recorded on declarations.
        if sourcePath != module.sourcePath:
          for declared in module.symbols:
            if declared.location.path == sourcePath:
              querySymbol.location.sourceTextHash = declared.location.sourceTextHash
              break
        var document: DocumentSnapshot
        var startOffset, finishOffset, offset: int
        if occurrence.atCall:
          if not self.cachedSourceDocumentFor(
            querySymbol.location, request.positionEncoding, sourceDocuments, document
          ):
            continue
          let text = document.lineText(request.line)
          var column = int(querySymbol.location.column)
          if column < text.len and text[column] == '(':
            dec column
            while column >= 0 and text[column] in {' ', '\t'}:
              dec column
            if column >= 0 and text[column] == ']':
              var brackets = 1
              dec column
              while column >= 0 and brackets > 0:
                if text[column] == ']':
                  inc brackets
                elif text[column] == '[':
                  dec brackets
                dec column
            while column >= 0 and (
              text[column] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'} or
              ord(text[column]) >= 128
            )
            :
              dec column
            querySymbol.location.column = int32(column + 1)
        if self.symbolSpan(
          querySymbol, request.positionEncoding, sourceDocuments, document, startOffset,
          finishOffset,
        ) and document.tryOffsetAt(position, offset) and offset >= startOffset and
            offset < finishOffset:
          targets.add(symbol)
          useSymbol = querySymbol
          useDocument = document
          useStart = startOffset
          useFinish = finishOffset
      if targets.len > 0:
        break
    if targets.len > 0:
      break
  var seen = initHashSet[string]()
  for symbol in targets:
    var document: DocumentSnapshot
    var startOffset, finishOffset: int
    if not self.symbolSpan(
      symbol, request.positionEncoding, sourceDocuments, document, startOffset,
      finishOffset,
    ):
      continue
    if seen.containsOrIncl(symbol.key):
      continue
    if request.kind == lrkDefinition:
      discard response.addLanguageSymbol(symbol, document, startOffset, finishOffset)
    else:
      discard response.addLanguageSymbol(useSymbol, useDocument, useStart, useFinish)
      response.preview =
        "**" & symbol.name & "**\n\n`" & symbol.kind & "` `" & symbol.qualifiedName & "`"
      if symbol.kind in ["proc", "func", "method", "iterator", "converter"]:
        response.preview.add("\n\n`" & self.semantic.raisesDisplay(symbol) & "`")
      break
  response.found = response.symbols.len > 0
  response.version = useDocument.version

proc installSemanticSnapshot(
    self: LanguageService, snapshot: sink SemanticSnapshot
) {.slot.} =
  self.configurationGeneration = snapshot.configurationGeneration
  self.configurationFingerprint = snapshot.configurationFingerprint
  self.compilerFingerprint = snapshot.compilerFingerprint
  self.occurrences.setLen(0)
  self.semantic = snapshot
  self.hasSemantic = true

proc processLanguageWork(self: LanguageService, work: LanguageWork) {.slot.} =
  if work.cancellation.isCancelled():
    emit self.languageResponse(work.cancelledResponse())
    return

  var response =
    LanguageResponse(ok: true, uri: work.request.uri, version: work.request.version)
  try:
    response.uri = normalizeDocumentUri(work.request.uri)
    case work.request.kind
    of lrkOpen:
      inc self.documentGeneration
      case self.documents.openDocument(
        work.request.uri, work.request.text, work.request.version,
        work.request.positionEncoding,
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
      inc self.documentGeneration
      case self.documents.updateDocument(
        work.request.uri, work.request.text, work.request.version,
        work.request.positionEncoding,
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
      inc self.documentGeneration
      discard self.documents.closeDocument(work.request.uri)
      for i in countdown(self.occurrences.high, 0):
        if self.occurrences[i].uri == response.uri:
          self.occurrences.delete(i)
    of lrkDocumentSymbols:
      if self.hasSemantic and work.request.stamp.valid and (
        work.request.stamp.documentGeneration != self.documentGeneration or
        work.request.stamp.configurationGeneration != self.configurationGeneration or
        work.request.stamp.configurationFingerprint != self.configurationFingerprint or
        work.request.stamp.compilerFingerprint != self.compilerFingerprint
      ):
        response.ok = false
        response.superseded = true
        response.error = "language request was superseded by newer state"
      else:
        self.addDocumentSymbols(
          response.uri, work.request.positionEncoding, response, work.cancellation
        )
    of lrkWorkspaceSymbols:
      if self.hasSemantic and work.request.stamp.valid and (
        work.request.stamp.documentGeneration != self.documentGeneration or
        work.request.stamp.configurationGeneration != self.configurationGeneration or
        work.request.stamp.configurationFingerprint != self.configurationFingerprint or
        work.request.stamp.compilerFingerprint != self.compilerFingerprint
      ):
        response.ok = false
        response.superseded = true
        response.error = "language request was superseded by newer state"
      else:
        self.addWorkspaceSymbols(
          work.request.query, work.request.positionEncoding, response, work.cancellation
        )
    of lrkHover, lrkDefinition:
      if self.hasSemantic and work.request.stamp.valid and (
        work.request.stamp.documentGeneration != self.documentGeneration or
        work.request.stamp.configurationGeneration != self.configurationGeneration or
        work.request.stamp.configurationFingerprint != self.configurationFingerprint or
        work.request.stamp.compilerFingerprint != self.compilerFingerprint
      ):
        response.ok = false
        response.superseded = true
        response.error = "language request was superseded by newer state"
      else:
        self.findPositionSymbol(work.request, response, work.cancellation)
    response.stamp = LanguageStamp(
      valid: work.request.stamp.valid,
      projectId: self.semantic.projectId,
      documentGeneration: self.documentGeneration,
      sourceGeneration: work.request.stamp.sourceGeneration,
      configurationGeneration: self.configurationGeneration,
      configurationFingerprint: self.configurationFingerprint,
      compilerFingerprint: self.compilerFingerprint,
      sourceFingerprint: self.semantic.sourceFingerprint,
    )
  except CatchableError as error:
    response.ok = false
    response.error = "language state error: " & error.msg
  except Defect as error:
    response.ok = false
    response.error = "language worker failure: " & error.msg

  if work.cancellation.isCancelled() and response.ok:
    response.ok = false
    response.cancelled = true
    response.error = "language request was cancelled"
  emit self.languageResponse(LanguageCompletion(id: work.id, response: response))

proc receiveLanguageResponse(
    self: LanguageReply, completion: LanguageCompletion
) {.slot.} =
  self.completions.add(completion)

proc newLanguageRuntime*(workers = 1, maxPending = 512): LanguageRuntime =
  ## Start a Sigils worker pool and attach one serialized document-state actor.
  if maxPending < 1:
    raise newException(ValueError, "language maxPending must be positive")
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
    nextWorkId: 1,
    pending: initTable[LanguageWorkId, ptr LanguageCancellation](),
    retired: initTable[LanguageWorkId, ptr LanguageCancellation](),
    maxPending: maxPending,
  )

  connectThreaded(result.source, languageWork, result.serviceProxy, processLanguageWork)
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

proc pendingCount*(runtime: LanguageRuntime): int =
  ## Return active and cancelled-but-not-retired work reservations.
  if runtime.isNil:
    return 0
  runtime.pending.len + runtime.retired.len

proc submit*(runtime: LanguageRuntime, request: LanguageRequest): LanguageWorkId =
  ## Queue one owned language operation and return its internal identity.
  ## A zero result means that the runtime is closed or at capacity.
  if runtime.isNil or runtime.closed or runtime.pendingCount() >= runtime.maxPending:
    return 0

  var id = runtime.nextWorkId
  if id == 0:
    id = 1
  runtime.nextWorkId = id + 1
  let cancellation = newLanguageCancellation()
  runtime.pending[id] = cancellation
  try:
    emit runtime.source.languageWork(
      LanguageWork(id: id, request: request, cancellation: cancellation)
    )
    id
  except CatchableError:
    runtime.pending.del(id)
    cancellation.releaseCancellation()
    0
  except Defect:
    runtime.pending.del(id)
    cancellation.releaseCancellation()
    0

proc cancel*(runtime: LanguageRuntime, id: LanguageWorkId): bool =
  ## Request cancellation at the shared checkpoint token.
  if runtime.isNil or runtime.closed or id notin runtime.pending:
    return false
  runtime.pending[id].markCancelled()
  true

proc abandon*(runtime: LanguageRuntime, id: LanguageWorkId): bool =
  ## Settle a protocol request while retaining the worker's capacity credit.
  if runtime.isNil or id notin runtime.pending:
    return false
  runtime.retired[id] = runtime.pending[id]
  runtime.pending.del(id)
  true

proc takeCompleted*(runtime: LanguageRuntime): seq[LanguageCompletion] =
  ## Drain worker completions after the caller has pumped its home scheduler.
  if runtime.isNil:
    return
  for completion in runtime.reply.completions:
    if completion.id in runtime.pending:
      let cancellation = runtime.pending[completion.id]
      runtime.pending.del(completion.id)
      cancellation.releaseCancellation()
      result.add(completion)
    elif completion.id in runtime.retired:
      let cancellation = runtime.retired[completion.id]
      runtime.retired.del(completion.id)
      cancellation.releaseCancellation()
    ## Unknown completions belong to a closed or failed request and are dropped.
  runtime.reply.completions.setLen(0)

proc pump*(runtime: LanguageRuntime, blocking: BlockingKinds = NonBlocking): int =
  ## Run home-thread deliveries so callers can drain asynchronous completions.
  if runtime.isNil:
    return 0
  case blocking
  of Blocking:
    if runtime.home.poll(Blocking): 1 else: 0
  of NonBlocking:
    runtime.home.pollAll(NonBlocking)

proc request*(runtime: LanguageRuntime, request: LanguageRequest): LanguageResponse =
  ## Compatibility helper for direct callers. Asynchronous LSP dispatch uses
  ## `submit` and `takeCompleted` instead of occupying a shared response slot.
  let id = runtime.submit(request)
  if id == 0:
    if runtime.isNil or runtime.closed:
      return LanguageResponse(ok: false, error: "language runtime is closed")
    return LanguageResponse(ok: false, error: "language request queue is full")

  while true:
    discard runtime.home.poll(Blocking)
    for completion in runtime.takeCompleted():
      if completion.id == id:
        return completion.response

proc close*(runtime: LanguageRuntime) =
  ## Stop the language worker pool after cancelling all admitted operations.
  if runtime.isNil or runtime.closed:
    return
  runtime.closed = true
  for cancellation in runtime.pending.values:
    cancellation.markCancelled()
  for cancellation in runtime.retired.values:
    cancellation.markCancelled()
  runtime.serviceProxy = nil
  runtime.pool.stop()
  runtime.pool.join()
  doAssert runtime.pool.disposeJoined()
  runtime.pool = nil
  for cancellation in runtime.pending.values:
    cancellation.releaseCancellation()
  for cancellation in runtime.retired.values:
    cancellation.releaseCancellation()
  runtime.pending.clear()
  runtime.retired.clear()
  runtime.reply.completions.setLen(0)
