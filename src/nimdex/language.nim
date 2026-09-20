## Worker-pool language components used by the Nimdex LSP server.

import ./documents

import sigils

type
  LanguageRequestKind* = enum ## Operations supported by the language component.
    lrkOpen ## Store a newly opened document.
    lrkChange ## Replace an open document's full text.
    lrkClose ## Remove a document from the worker state.
    lrkHover ## Query compiler-backed hover information when available.

  LanguageRequest* = object ## A language operation sent to worker-owned state.
    kind*: LanguageRequestKind ## The operation to perform.
    uri*: string ## The LSP document URI.
    version*: int ## The document version supplied by the client.
    text*: string ## Full document text for open and change operations.
    line*: int ## Zero-based line for a hover query.
    character*: int ## Zero-based character for a hover query.
    positionEncoding*: PositionEncoding ## Client character-unit encoding.

  LanguageResponse* = object
    ## The deterministic result returned by worker-owned language state.
    ok*: bool ## Whether the operation completed successfully.
    found*: bool ## Whether a hover query found an open document.
    uri*: string ## The URI associated with the operation.
    version*: int ## The current document version for a successful query.
    preview*: string ## Hover text when compiler-backed analysis is available.
    error*: string ## A diagnostic description when `ok` is false.

  LanguageSource = ref object of AgentActor

  LanguageService = ref object of AgentActor
    documents: DocumentStore

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
    of lrkHover:
      var document: DocumentSnapshot
      if self.documents.tryFindDocument(request.uri, document):
        response.version = document.version
        response.ok = false
        response.error =
          "analysis unavailable: no compiler-backed semantic snapshot is installed"
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
