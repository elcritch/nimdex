## Safe, offline discovery and indexing of compiler-produced semantic BIFs.

import std/[algorithm, cpuinfo, os, sha1, strutils, tables, times]

import binny/bif_safe
import chronicles
import sigils

import ./binnycompat
import ./documents
import ./semantic
import ./workspace

export semantic

type
  BifIndexOptions* = object
    loadLimits*: BifLoadLimits
    maxArtifacts*: int
    ## Zero selects the machine's processor count. A positive value is useful
    ## for callers that want to cap indexing parallelism explicitly.
    workerCount*: int

  BifIndex* = SemanticSnapshot

  BifReuseCache* = object
    modules: Table[string, ModuleSnapshot]
    loadedArtifacts*: int
    reusedArtifacts*: int

  BifIndexResult = object
    artifactPath: string
    ready: bool
    module: ModuleSnapshot
    failure: AnalysisFailure

  BifLoadTrigger = ref object of AgentActor

  BifLoadWorker = ref object of AgentActor
    artifactPath: string
    limits: BifLoadLimits
    projectId: string

  BifLoadCollector = ref object of AgentActor
    expected: int
    completed: int
    results: seq[BifIndexResult]

const DefaultBifIndexOptions* = BifIndexOptions(
  loadLimits: DefaultBinnyLoadLimits, maxArtifacts: 10000, workerCount: 0
)

proc failureFromReport(report: BinnyArtifactReport): AnalysisFailure
proc moduleFromReport(report: BinnyArtifactReport, projectId: string): ModuleSnapshot

proc triggerLoad(trigger: BifLoadTrigger) {.signal.}
proc indexCompleted(worker: BifLoadWorker, item: BifIndexResult) {.signal.}

proc indexArtifact(worker: BifLoadWorker) {.slot.} =
  var indexed: BifIndexResult
  debug "Indexing BIF artifact", artifactPath = worker.artifactPath
  try:
    let report = inspectBinnyArtifact(worker.artifactPath, worker.limits)
    indexed.artifactPath = report.path
    if report.isReady():
      indexed.ready = true
      indexed.module = moduleFromReport(report, worker.projectId)
      debug "Indexed BIF module",
        artifactPath = indexed.module.artifactPath,
        sourcePath = indexed.module.sourcePath,
        symbolCount = indexed.module.symbols.len,
        tokenCount = indexed.module.tokenCount
    else:
      indexed.failure = failureFromReport(report)
      warn "Skipping BIF artifact that could not be indexed",
        artifactPath = indexed.failure.artifactPath,
        failureKind = $indexed.failure.kind,
        failure = indexed.failure.message
  except CatchableError as error:
    ## The safe loader normally reports malformed input as data. Keep an
    ## unexpected filesystem/runtime failure from stranding the whole batch.
    indexed.artifactPath = worker.artifactPath
    indexed.failure =
      AnalysisFailure(artifactPath: worker.artifactPath, kind: afIo, message: error.msg)
    warn "Unexpected error while indexing BIF artifact",
      artifactPath = worker.artifactPath, failure = error.msg
  emit worker.indexCompleted(indexed)

proc collectArtifact(collector: BifLoadCollector, result: BifIndexResult) {.slot.} =
  collector.results.add(result)
  inc collector.completed

proc requestedWorkerCount(options: BifIndexOptions, artifactCount: int): int =
  if artifactCount == 0:
    return 0
  let configured =
    if options.workerCount > 0:
      options.workerCount
    else:
      countProcessors()
  min(max(configured, 1), artifactCount)

proc indexArtifactsInPool(
    artifacts: openArray[string], projectId: string, options: BifIndexOptions
): seq[BifIndexResult] =
  ## Run one independent loader/indexer actor per artifact. Sigils serializes each
  ## actor's state while allowing the independent actors to occupy workers in
  ## parallel, then delivers owned semantic records back to this thread.
  if artifacts.len == 0:
    return

  let workerCount = requestedWorkerCount(options, artifacts.len)
  info "Starting parallel BIF indexing",
    artifactCount = artifacts.len, workerCount = workerCount, projectId = projectId
  startLocalThreadDefault()
  let pool = newSigilThreadPool(workers = workerCount)
  pool.start()

  var collector = BifLoadCollector(expected: artifacts.len)
  var triggers: seq[BifLoadTrigger]
  var proxies: seq[AgentProxy[BifLoadWorker]]
  for artifactPath in artifacts:
    var trigger = BifLoadTrigger.new()
    var worker = BifLoadWorker(
      artifactPath: artifactPath, limits: options.loadLimits, projectId: projectId
    )
    let workerProxy = worker.moveToThread(pool)
    connectThreaded(
      workerProxy, indexCompleted, collector, collectArtifact(BifLoadCollector)
    )
    connectThreaded(trigger, triggerLoad, workerProxy, indexArtifact)
    triggers.add(trigger)
    proxies.add(workerProxy)

  for trigger in triggers:
    emit trigger.triggerLoad()

  while collector.completed < collector.expected:
    discard getCurrentSigilThread().poll()

  pool.stop()
  pool.join()
  result = collector.results

proc discoverBifArtifacts*(roots: openArray[string]): seq[string] =
  ## Discover only semantic BIF files using ordinary filesystem traversal.
  for root in roots:
    let normalizedRoot = normalizeDocumentPath(root)
    if fileExists(normalizedRoot):
      if normalizedRoot.endsWith(".s.bif"):
        result.add(normalizedRoot)
      continue
    if not dirExists(normalizedRoot):
      continue
    for path in walkDirRec(normalizedRoot):
      if path.endsWith(".s.bif"):
        result.add(path)
  result.sort()

  var unique: seq[string]
  for path in result:
    if unique.len == 0 or unique[^1] != path:
      unique.add(path)
  result = unique

proc mapFailureKind(kind: BifErrorKind): AnalysisFailureKind =
  case kind
  of bekIo: afIo
  of bekTruncated: afTruncated
  of bekInvalidMagic: afInvalidMagic
  of bekUnsupportedFormat: afUnsupportedFormat
  of bekInvalidData: afInvalidData
  of bekInvalidIndex: afInvalidIndex
  of bekLimitExceeded: afLimitExceeded

proc failureFromReport(report: BinnyArtifactReport): AnalysisFailure =
  result.artifactPath = report.path
  result.sourcePath = report.sourcePath
  if report.status == basMetadataIncomplete:
    result.kind = afMetadataIncomplete
    result.message = report.metadataError
  else:
    result.kind = mapFailureKind(report.failure.kind)
    result.message = report.failure.message

proc symbolBaseName(qualifiedName: string): string =
  let separator = qualifiedName.find('.')
  if separator < 0:
    qualifiedName
  else:
    qualifiedName[0 ..< separator]

proc sourceTextHashForPath(path: string): uint64 =
  if path.len == 0 or not fileExists(path):
    return 0
  try:
    stableTextHash(readFile(path))
  except CatchableError:
    0

proc modificationTimeForPath(path: string): int64 =
  if path.len == 0 or not fileExists(path):
    return 0
  try:
    int64(getLastModificationTime(path).toUnixFloat() * 1_000_000_000.0)
  except CatchableError:
    0

proc sourceHashForPath(hashes: var Table[string, uint64], path: string): uint64 =
  if path.len == 0:
    return 0
  if path notin hashes:
    hashes[path] = sourceTextHashForPath(path)
  hashes[path]

proc sourceLocation(
    sourcePath, sourceUri: string,
    location: BinnyLocation,
    sourceTextHash: uint64,
    artifactModifiedUnix: int64,
): SourceLocation =
  result.path = sourcePath
  result.uri = sourceUri
  result.sourceTextHash = sourceTextHash
  result.artifactModifiedUnix = artifactModifiedUnix
  result.valid = location.valid
  result.line = location.line
  result.column = location.column

proc moduleFromReport(report: BinnyArtifactReport, projectId: string): ModuleSnapshot =
  result.artifactPath = report.path
  let filename = report.path.extractFilename()
  result.moduleId = filename[0 ..< filename.len - ".s.bif".len]
  result.imports = report.imports
  for path in report.includes:
    result.includes.add(normalizeDocumentPath(path))
  result.sourcePath = normalizeDocumentPath(report.sourcePath)
  result.sourceUri = documentUriFromPath(result.sourcePath)
  result.artifactModifiedUnix = modificationTimeForPath(report.path)
  result.tokenCount = report.tokenCount
  result.tagCount = report.tagCount
  result.stringCount = report.stringCount
  result.symbolPoolCount = report.symbolCount
  result.filenameCount = report.filenameCount
  var canonicalPaths = initTable[string, string]()
  var sourceUris = initTable[string, string]()
  for path in report.sourceFiles:
    canonicalPaths[path] = normalizeDocumentPath(path)
    result.sourceFiles.add(canonicalPaths[path])
  canonicalPaths[report.sourcePath] = result.sourcePath
  var sourceHashes = initTable[string, uint64]()
  result.sourceTextHash = sourceHashForPath(sourceHashes, result.sourcePath)
  result.tags = report.tags
  var symbols: seq[SymbolInfo]
  for declaration in report.declarations:
    let modulePath = if result.sourcePath.len > 0: result.sourcePath else: report.path
    let rawPath =
      if declaration.location.file.len > 0:
        declaration.location.file
      else:
        report.sourcePath
    if rawPath notin canonicalPaths:
      canonicalPaths[rawPath] = normalizeDocumentPath(rawPath)
    let locationPath = canonicalPaths[rawPath]
    if locationPath notin sourceUris:
      sourceUris[locationPath] = documentUriFromPath(locationPath)
    symbols.add(
      SymbolInfo(
        key: projectId & "\0" & modulePath & "\0" & declaration.name,
        name: symbolBaseName(declaration.name),
        qualifiedName: declaration.name,
        modulePath: modulePath,
        kind: declaration.tag,
        visibility: if declaration.visibility == bvisExported: svExported else: svHidden,
        location: sourceLocation(
          locationPath,
          sourceUris[locationPath],
          declaration.location,
          sourceHashForPath(sourceHashes, locationPath),
          result.artifactModifiedUnix,
        ),
      )
    )
  result.setSymbols(move(symbols))

proc buildBifIndexCached*(
    workspace: Workspace,
    cache: var BifReuseCache,
    artifactRoots: seq[string] = @[],
    options = DefaultBifIndexOptions,
): BifIndex =
  result = initSemanticSnapshot(
    workspace.projectId, workspace.configurationGeneration,
    workspace.configurationFingerprint,
  )
  let roots = if artifactRoots.len > 0: artifactRoots else: workspace.artifactRoots
  info "Discovering BIF artifacts",
    projectId = workspace.projectId,
    artifactRoots = roots,
    maxArtifacts = options.maxArtifacts
  let artifacts = discoverBifArtifacts(roots)
  debug "Discovered BIF artifacts",
    artifactCount = artifacts.len, artifactPaths = artifacts
  if options.maxArtifacts >= 0 and artifacts.len > options.maxArtifacts:
    warn "BIF artifact limit exceeded",
      artifactCount = artifacts.len, maxArtifacts = options.maxArtifacts
    result.addFailure(
      AnalysisFailure(
        kind: afArtifactLimit, message: "BIF artifact count exceeds configured limit"
      )
    )

  let count =
    if options.maxArtifacts >= 0:
      min(artifacts.len, options.maxArtifacts)
    else:
      artifacts.len
  var selectedArtifacts: seq[string]
  for index in 0 ..< count:
    selectedArtifacts.add(artifacts[index])
  var pending: seq[string]
  var hashes = initTable[string, string]()
  var indexed: seq[BifIndexResult]
  for path in selectedArtifacts:
    # Respect loader limits before reading bytes for the content cache.
    if getFileSize(path) <= options.loadLimits.maxFileBytes:
      hashes[path] = $secureHashFile(path)
    let hash = hashes.getOrDefault(path)
    if hash.len > 0 and hash in cache.modules:
      var module = cache.modules[hash]
      module.artifactPath = path
      module.artifactModifiedUnix = modificationTimeForPath(path)
      module.headFiles = @[]
      var sourceHashes = initTable[string, uint64]()
      module.sourceTextHash = sourceHashForPath(sourceHashes, module.sourcePath)
      var sourceTimes = initTable[string, int64]()
      var changed = false
      for symbol in module.symbols:
        let source = symbol.location.path
        if source notin sourceTimes:
          sourceTimes[source] = modificationTimeForPath(source)
        if sourceHashForPath(sourceHashes, source) != symbol.location.sourceTextHash or
            sourceTimes[source] > symbol.location.artifactModifiedUnix:
          changed = true
      if changed:
        var symbols = module.symbols
        for symbol in symbols.mitems:
          symbol.location.sourceTextHash = sourceHashes[symbol.location.path]
          symbol.location.artifactModifiedUnix = module.artifactModifiedUnix
        module.setSymbols(move(symbols))
      indexed.add(BifIndexResult(artifactPath: path, ready: true, module: module))
      inc cache.reusedArtifacts
    else:
      pending.add(path)
  indexed.add(indexArtifactsInPool(pending, workspace.projectId, options))
  cache.loadedArtifacts += pending.len
  indexed.sort(
    proc(a, b: BifIndexResult): int =
      cmp(a.artifactPath, b.artifactPath)
  )
  var indexedSymbolCount = 0
  for item in indexed.mitems:
    if not item.ready:
      result.addFailure(item.failure)
      continue
    indexedSymbolCount += item.module.symbols.len
    item.module.artifactHash = hashes.getOrDefault(item.artifactPath)
    if item.module.artifactHash.len > 0:
      cache.modules[item.module.artifactHash] = item.module
    result.addModule(item.module)
  info "Completed BIF indexing",
    projectId = workspace.projectId,
    discoveredArtifacts = artifacts.len,
    indexedArtifacts = selectedArtifacts.len,
    moduleCount = result.moduleCount(),
    symbolCount = indexedSymbolCount,
    tokenCount = result.tokenCount(),
    failureCount = result.failureCount()

proc buildBifIndex*(
    workspace: Workspace,
    artifactRoots: seq[string] = @[],
    options = DefaultBifIndexOptions,
): BifIndex =
  var cache: BifReuseCache
  buildBifIndexCached(workspace, cache, artifactRoots, options)

proc rememberModules*(cache: var BifReuseCache, snapshot: SemanticSnapshot) =
  for module in snapshot.modules:
    if module.artifactHash.len > 0:
      cache.modules[module.artifactHash] = module
