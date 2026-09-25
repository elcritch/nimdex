## Owned semantic records and lookup tables independent of Binny and LSP JSON.

import std/[sets, strutils, tables]

import chronicles
import ./modulegraph

export modulegraph

type
  AnalysisStamp* = object ## Identity of the source/configuration used by analysis.
    valid*: bool
    projectId*: string
    documentGeneration*: uint64
    sourceGeneration*: uint64
    configurationGeneration*: uint64
    configurationFingerprint*: uint64
    compilerFingerprint*: uint64
    sourceFingerprint*: uint64

  SemanticVisibility* = enum
    svHidden
    svExported

  SourceLocation* = object
    valid*: bool
    uri*: string
    path*: string
    sourceTextHash*: uint64
    artifactModifiedUnix*: int64
    line*: int32
    column*: int32

  SymbolInfo* = object
    key*: string
    name*: string
    qualifiedName*: string
    modulePath*: string
    kind*: string
    visibility*: SemanticVisibility
    location*: SourceLocation
    instantiatedFrom*: string
    typeId*: string
    raisesKnown*: bool
    raisesTypes*: seq[string]

  ModuleSymbols = ref object
    ## Immutable after extraction; Nim's atomic ARC owns sharing across actors.
    values: seq[SymbolInfo]

  ModuleSnapshot* = object
    moduleId*: string
    artifactHash*: string
    imports*: seq[string]
    includes*: seq[string]
    headFiles*: seq[string]
    artifactPath*: string
    sourcePath*: string
    sourceUri*: string
    sourceTextHash*: uint64
    artifactModifiedUnix*: int64
    tokenCount*: int
    tagCount*: int
    stringCount*: int
    symbolPoolCount*: int
    filenameCount*: int
    sourceFiles*: seq[string]
    tags*: seq[string]
    symbolData: ModuleSymbols

  AnalysisFailureKind* = enum
    afIo
    afTruncated
    afInvalidMagic
    afUnsupportedFormat
    afInvalidData
    afInvalidIndex
    afLimitExceeded
    afMetadataIncomplete
    afNoSourcePath
    afArtifactLimit

  AnalysisFailure* = object
    artifactPath*: string
    sourcePath*: string
    kind*: AnalysisFailureKind
    message*: string

  SymbolRef = object
    moduleIndex: int
    symbolIndex: int

  SemanticLookups = ref object
    nameIndex: Table[string, seq[SymbolRef]]
    locationIndex: Table[string, seq[SymbolRef]]
    contentIndex: Table[string, int]

  SemanticSnapshot* = object ## An owned, queryable set of semantic module records.
    projectId*: string
    configurationGeneration*: uint64
    configurationFingerprint*: uint64
    compilerFingerprint*: uint64
    sourceFingerprint*: uint64
    analysisStamp*: AnalysisStamp
    modules*: seq[ModuleSnapshot]
    failures*: seq[AnalysisFailure]
    graph*: ModuleGraph
    preferredHeads*: Table[string, string] ## Explicit source-to-head context choices.
    lookups: SemanticLookups

proc symbols*(module: ModuleSnapshot): lent seq[SymbolInfo] =
  ## Read the immutable declaration records shared by identical BIF modules.
  if module.symbolData.isNil:
    return
  module.symbolData.values

proc setSymbols*(module: var ModuleSnapshot, symbols: sink seq[SymbolInfo]) =
  ## Replace the payload without changing records held by earlier snapshots.
  module.symbolData = ModuleSymbols(values: symbols)

proc initSemanticSnapshot*(
    projectId: string,
    configurationGeneration: uint64,
    configurationFingerprint: uint64 = 0,
): SemanticSnapshot =
  result.projectId = projectId
  result.configurationGeneration = configurationGeneration
  result.configurationFingerprint = configurationFingerprint
  result.analysisStamp = AnalysisStamp(
    valid: true,
    projectId: projectId,
    configurationGeneration: configurationGeneration,
    configurationFingerprint: configurationFingerprint,
  )
  result.lookups = SemanticLookups()

proc locationKey(location: SourceLocation): string =
  location.uri & '\0' & $location.line & '\0' & $location.column

proc addNameRef(snapshot: var SemanticSnapshot, name: string, reference: SymbolRef) =
  if name.len == 0:
    return
  snapshot.lookups.nameIndex.mgetOrPut(name, @[]).add(reference)

proc addLocationRef(
    snapshot: var SemanticSnapshot, location: SourceLocation, reference: SymbolRef
) =
  if not location.valid or location.uri.len == 0:
    return
  snapshot.lookups.locationIndex.mgetOrPut(locationKey(location), @[]).add(reference)

proc addModule*(snapshot: var SemanticSnapshot, module: sink ModuleSnapshot) =
  if snapshot.lookups.isNil:
    snapshot.lookups = SemanticLookups()
  elif not isUniqueRef(snapshot.lookups):
    snapshot.lookups = SemanticLookups(
      nameIndex: snapshot.lookups.nameIndex,
      locationIndex: snapshot.lookups.locationIndex,
      contentIndex: snapshot.lookups.contentIndex,
    )
  let contentKey = module.artifactHash & "\0" & $module.sourceTextHash
  if module.artifactHash.len > 0 and contentKey in snapshot.lookups.contentIndex:
    let index = snapshot.lookups.contentIndex[contentKey]
    for head in module.headFiles:
      if head notin snapshot.modules[index].headFiles:
        snapshot.modules[index].headFiles.add(head)
    return
  debug "Adding module to semantic index",
    artifactPath = module.artifactPath,
    sourcePath = module.sourcePath,
    symbolCount = module.symbols.len,
    tokenCount = module.tokenCount
  let moduleIndex = snapshot.modules.len
  if module.artifactHash.len > 0:
    snapshot.lookups.contentIndex[contentKey] = moduleIndex
  snapshot.modules.add(module)
  for symbolIndex, symbol in snapshot.modules[moduleIndex].symbols:
    let reference = SymbolRef(moduleIndex: moduleIndex, symbolIndex: symbolIndex)
    trace "Indexing semantic symbol",
      name = symbol.name,
      qualifiedName = symbol.qualifiedName,
      kind = symbol.kind,
      modulePath = symbol.modulePath,
      sourcePath = symbol.location.path,
      line = symbol.location.line,
      column = symbol.location.column
    snapshot.addNameRef(symbol.name, reference)
    snapshot.addNameRef(symbol.qualifiedName, reference)
    snapshot.addNameRef(symbol.typeId, reference)
    snapshot.addLocationRef(symbol.location, reference)

proc addFailure*(snapshot: var SemanticSnapshot, failure: sink AnalysisFailure) =
  snapshot.failures.add(failure)

proc moduleCount*(snapshot: SemanticSnapshot): int =
  snapshot.modules.len

proc failureCount*(snapshot: SemanticSnapshot): int =
  snapshot.failures.len

proc findSymbols*(
    snapshot: SemanticSnapshot, name: string, head = "", localModule = ""
): seq[SymbolInfo] =
  ## Return owned copies of symbols matching a base or qualified name.
  if snapshot.lookups.isNil:
    for module in snapshot.modules:
      if (head.len > 0 and head notin module.headFiles) or
          (localModule.len > 0 and localModule != module.sourcePath):
        continue
      for symbol in module.symbols:
        if name in [symbol.name, symbol.qualifiedName, symbol.typeId]:
          result.add(symbol)
    return
  if name notin snapshot.lookups.nameIndex:
    return
  for reference in snapshot.lookups.nameIndex[name]:
    let module = snapshot.modules[reference.moduleIndex]
    if head.len > 0 and head notin module.headFiles:
      continue
    if localModule.len > 0 and module.sourcePath != localModule:
      continue
    result.add(snapshot.modules[reference.moduleIndex].symbols[reference.symbolIndex])

proc symbolsInDocument*(snapshot: SemanticSnapshot, uri: string): seq[SymbolInfo] =
  ## Return all owned symbols whose verified location belongs to one document.
  var seen = initHashSet[string]()
  for module in snapshot.modules:
    if module.sourceUri != uri:
      continue
    for symbol in module.symbols:
      if symbol.location.valid and symbol.location.uri == uri and
          not seen.containsOrIncl(symbol.key):
        result.add(symbol)

proc symbolsMatching*(snapshot: SemanticSnapshot, query: string): seq[SymbolInfo] =
  ## Return symbols whose display or qualified name contains `query`.
  let needle = query.toLowerAscii()
  var seen = initHashSet[string]()
  for module in snapshot.modules:
    for symbol in module.symbols:
      if needle.len == 0 or symbol.name.toLowerAscii().contains(needle) or
          symbol.qualifiedName.toLowerAscii().contains(needle):
        if not seen.containsOrIncl(symbol.key):
          result.add(symbol)

proc recordHead*(snapshot: var SemanticSnapshot, head: string) =
  ## Resolve suffixes within this compiler context before combining snapshots.
  var paths = initTable[string, string]()
  for module in snapshot.modules:
    paths[module.moduleId] = module.sourcePath
  var dependencies: seq[ModuleDependencies]
  for module in snapshot.modules.mitems:
    module.headFiles = @[head]
    var entry =
      ModuleDependencies(sourcePath: module.sourcePath, includes: module.includes)
    for suffix in module.imports:
      if suffix in paths:
        entry.imports.add(paths[suffix])
      else:
        entry.unresolvedImports.add(suffix)
    dependencies.add(entry)
  snapshot.graph.addHead(head, dependencies, compiledClosure = true)

proc mergeHead*(snapshot: var SemanticSnapshot, headSnapshot: SemanticSnapshot) =
  for head in headSnapshot.graph.heads:
    var dependencies: seq[ModuleDependencies]
    for entry in headSnapshot.graph.modules.values:
      dependencies.add(entry)
    snapshot.graph.addHead(head, dependencies, compiledClosure = true)
  for module in headSnapshot.modules:
    snapshot.addModule(module)

proc symbolsAt*(
    snapshot: SemanticSnapshot, uri: string, line, column: int32
): seq[SymbolInfo] =
  let key = uri & '\0' & $line & '\0' & $column
  if snapshot.lookups.isNil:
    for module in snapshot.modules:
      for symbol in module.symbols:
        if symbol.location.valid and locationKey(symbol.location) == key:
          result.add(symbol)
    return
  if key notin snapshot.lookups.locationIndex:
    return
  for reference in snapshot.lookups.locationIndex[key]:
    result.add(snapshot.modules[reference.moduleIndex].symbols[reference.symbolIndex])

proc findModule*(snapshot: SemanticSnapshot, sourcePath: string): ModuleSnapshot =
  for module in snapshot.modules:
    if module.sourcePath == sourcePath:
      return module
  raise newException(KeyError, "semantic module not found: " & sourcePath)

proc containsModule*(snapshot: SemanticSnapshot, sourcePath: string): bool =
  for module in snapshot.modules:
    if module.sourcePath == sourcePath:
      return true
  false

proc tokenCount*(snapshot: SemanticSnapshot): int =
  ## Return the total number of raw BIF tokens in the owned snapshot.
  for module in snapshot.modules:
    result += module.tokenCount

proc compactHead*(snapshot: var SemanticSnapshot) =
  ## Retained heads supply immutable modules; only the merged query snapshot
  ## needs name/location indexes. Call after constructing a head, before sharing.
  snapshot.lookups = nil

proc raisesDisplay*(snapshot: SemanticSnapshot, symbol: SymbolInfo): string =
  ## Unknown effects stay distinct from the compiler-proven empty effect set.
  if not symbol.raisesKnown:
    return "raises: unknown"
  var names: seq[string]
  for identity in symbol.raisesTypes:
    var name = ""
    if identity.startsWith("`t"):
      for typ in snapshot.findSymbols(identity):
        if typ.typeId == identity:
          name = typ.name
          break
    else:
      name = identity.split('.')[0]
    if name.len == 0:
      return "raises: unknown"
    if name notin names:
      names.add(name)
  "raises: [" & names.join(", ") & "]"
