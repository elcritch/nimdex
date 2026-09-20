## Safe, offline discovery and indexing of compiler-produced semantic BIFs.

import std/[algorithm, cpuinfo, os, strutils, tables, times]

import binny/bif_safe
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
  try:
    let report = inspectBinnyArtifact(worker.artifactPath, worker.limits)
    indexed.artifactPath = report.path
    if report.isReady():
      indexed.ready = true
      indexed.module = moduleFromReport(report, worker.projectId)
    else:
      indexed.failure = failureFromReport(report)
  except CatchableError as error:
    ## The safe loader normally reports malformed input as data. Keep an
    ## unexpected filesystem/runtime failure from stranding the whole batch.
    indexed.artifactPath = worker.artifactPath
    indexed.failure =
      AnalysisFailure(artifactPath: worker.artifactPath, kind: afIo, message: error.msg)
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

  startLocalThreadDefault()
  let pool = newSigilThreadPool(workers = requestedWorkerCount(options, artifacts.len))
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
  let normalized = normalizeDocumentPath(path)
  if normalized.len == 0:
    return 0
  if normalized notin hashes:
    hashes[normalized] = sourceTextHashForPath(normalized)
  hashes[normalized]

proc sourceLocation(
    sourcePath: string,
    location: BinnyLocation,
    sourceTextHash: uint64,
    artifactModifiedUnix: int64,
): SourceLocation =
  result.path =
    normalizeDocumentPath(if location.file.len > 0: location.file else: sourcePath)
  if result.path.len > 0:
    result.uri = documentUriFromPath(result.path)
  result.sourceTextHash = sourceTextHash
  result.artifactModifiedUnix = artifactModifiedUnix
  result.valid = location.valid
  result.line = location.line
  result.column = location.column

proc moduleFromReport(report: BinnyArtifactReport, projectId: string): ModuleSnapshot =
  result.artifactPath = report.path
  result.sourcePath = normalizeDocumentPath(report.sourcePath)
  result.sourceUri = documentUriFromPath(result.sourcePath)
  result.artifactModifiedUnix = modificationTimeForPath(report.path)
  var sourceHashes = initTable[string, uint64]()
  result.sourceTextHash = sourceHashForPath(sourceHashes, result.sourcePath)
  result.tags = report.tags
  for declaration in report.declarations:
    let modulePath = if result.sourcePath.len > 0: result.sourcePath else: report.path
    let locationPath =
      if declaration.location.file.len > 0:
        declaration.location.file
      else:
        report.sourcePath
    result.symbols.add(
      SymbolInfo(
        key: projectId & "\0" & modulePath & "\0" & declaration.name,
        name: symbolBaseName(declaration.name),
        qualifiedName: declaration.name,
        modulePath: modulePath,
        kind: declaration.tag,
        visibility: if declaration.visibility == bvisExported: svExported else: svHidden,
        location: sourceLocation(
          report.sourcePath,
          declaration.location,
          sourceHashForPath(sourceHashes, locationPath),
          result.artifactModifiedUnix,
        ),
      )
    )

proc buildBifIndex*(
    workspace: Workspace,
    artifactRoots: seq[string] = @[],
    options = DefaultBifIndexOptions,
): BifIndex =
  result = initSemanticSnapshot(workspace.projectId, workspace.configurationGeneration)
  let roots = if artifactRoots.len > 0: artifactRoots else: workspace.artifactRoots
  let artifacts = discoverBifArtifacts(roots)
  if options.maxArtifacts >= 0 and artifacts.len > options.maxArtifacts:
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
  var indexed = indexArtifactsInPool(selectedArtifacts, workspace.projectId, options)
  indexed.sort(
    proc(a, b: BifIndexResult): int =
      cmp(a.artifactPath, b.artifactPath)
  )
  for item in indexed:
    if not item.ready:
      result.addFailure(item.failure)
      continue
    result.addModule(item.module)
