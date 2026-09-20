## Worker-pool language components used by the Nimdex LSP server.

import std/[strutils, tables]

import sigils

type
  LanguageRequestKind* = enum ## Operations supported by the language shim.
    lrkOpen ## Store a newly opened document.
    lrkChange ## Replace an open document's full text.
    lrkClose ## Remove a document from the worker state.
    lrkHover ## Query the shimmed hover information for a document.

  LanguageRequest* = object ## A language operation sent to the worker-owned shim.
    kind*: LanguageRequestKind ## The operation to perform.
    uri*: string ## The LSP document URI.
    version*: int ## The document version supplied by the client.
    text*: string ## Full document text for open and change operations.
    line*: int ## Zero-based line for a hover query.
    character*: int ## Zero-based character for a hover query.

  LanguageResponse* = object
    ## The deterministic result returned by the worker-owned shim.
    ok*: bool ## Whether the operation completed successfully.
    found*: bool ## Whether a hover query found an open document.
    uri*: string ## The URI associated with the operation.
    version*: int ## The current document version for a successful query.
    preview*: string ## A short preview used by the shimmed hover response.
    error*: string ## A diagnostic description when `ok` is false.

  LanguageDocument = object
    version: int
    text: string

  LanguageSource = ref object of AgentActor

  LanguageService = ref object of AgentActor
    documents: Table[string, LanguageDocument]

  LanguageReply = ref object of AgentActor
    responseReady: bool
    response: LanguageResponse

  LanguageRuntime* = ref object ## Main-thread bridge to the worker-owned language shim.
    home: SigilThreadPtr
    pool: SigilThreadPoolPtr
    source: LanguageSource
    reply: LanguageReply
    serviceProxy: AgentProxy[LanguageService]
    closed: bool

proc languageRequest(source: LanguageSource, request: LanguageRequest) {.signal.}
proc languageResponse(source: LanguageService, response: LanguageResponse) {.signal.}

proc firstLinePreview(text: string): string =
  result = text
  let lineEnd = result.find('\n')
  if lineEnd >= 0:
    result.setLen(lineEnd)
  if result.len > 120:
    result.setLen(120)

proc processLanguageRequest(self: LanguageService, request: LanguageRequest) {.slot.} =
  var response = LanguageResponse(ok: true, uri: request.uri, version: request.version)

  case request.kind
  of lrkOpen:
    self.documents[request.uri] =
      LanguageDocument(version: request.version, text: request.text)
  of lrkChange:
    if request.uri notin self.documents:
      response.ok = false
      response.error = "document is not open"
    else:
      self.documents[request.uri] =
        LanguageDocument(version: request.version, text: request.text)
  of lrkClose:
    self.documents.del(request.uri)
  of lrkHover:
    if request.uri in self.documents:
      let document = self.documents[request.uri]
      response.found = true
      response.version = document.version
      response.preview = firstLinePreview(document.text)

  emit self.languageResponse(response)

proc receiveLanguageResponse(self: LanguageReply, response: LanguageResponse) {.slot.} =
  self.response = response
  self.responseReady = true

proc newLanguageRuntime*(workers = 1): LanguageRuntime =
  ## Start a Sigils worker pool and attach one serialized language actor to it.
  startLocalThreadDefault()
  let pool = newSigilThreadPool(workers = workers)
  pool.start()

  var service = LanguageService(documents: initTable[string, LanguageDocument]())
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
