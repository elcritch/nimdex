## Owned semantic records and lookup tables independent of Binny and LSP JSON.

import std/tables

type
  SemanticVisibility* = enum
    svHidden
    svExported

  SourceLocation* = object
    valid*: bool
    uri*: string
    path*: string
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

  ModuleSnapshot* = object
    artifactPath*: string
    sourcePath*: string
    sourceUri*: string
    tags*: seq[string]
    symbols*: seq[SymbolInfo]

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

  SemanticSnapshot* = object ## An owned, queryable set of semantic module records.
    projectId*: string
    configurationGeneration*: uint64
    modules*: seq[ModuleSnapshot]
    failures*: seq[AnalysisFailure]
    nameIndex: Table[string, seq[SymbolRef]]
    locationIndex: Table[string, seq[SymbolRef]]

proc initSemanticSnapshot*(
    projectId: string, configurationGeneration: uint64
): SemanticSnapshot =
  result.projectId = projectId
  result.configurationGeneration = configurationGeneration
  result.nameIndex = initTable[string, seq[SymbolRef]]()
  result.locationIndex = initTable[string, seq[SymbolRef]]()

proc locationKey(location: SourceLocation): string =
  location.uri & '\0' & $location.line & '\0' & $location.column

proc addNameRef(snapshot: var SemanticSnapshot, name: string, reference: SymbolRef) =
  if name.len == 0:
    return
  snapshot.nameIndex.mgetOrPut(name, @[]).add(reference)

proc addLocationRef(
    snapshot: var SemanticSnapshot, location: SourceLocation, reference: SymbolRef
) =
  if not location.valid or location.uri.len == 0:
    return
  snapshot.locationIndex.mgetOrPut(locationKey(location), @[]).add(reference)

proc addModule*(snapshot: var SemanticSnapshot, module: sink ModuleSnapshot) =
  let moduleIndex = snapshot.modules.len
  snapshot.modules.add(module)
  for symbolIndex, symbol in snapshot.modules[moduleIndex].symbols:
    let reference = SymbolRef(moduleIndex: moduleIndex, symbolIndex: symbolIndex)
    snapshot.addNameRef(symbol.name, reference)
    snapshot.addNameRef(symbol.qualifiedName, reference)
    snapshot.addLocationRef(symbol.location, reference)

proc addFailure*(snapshot: var SemanticSnapshot, failure: sink AnalysisFailure) =
  snapshot.failures.add(failure)

proc moduleCount*(snapshot: SemanticSnapshot): int =
  snapshot.modules.len

proc failureCount*(snapshot: SemanticSnapshot): int =
  snapshot.failures.len

proc findSymbols*(snapshot: SemanticSnapshot, name: string): seq[SymbolInfo] =
  ## Return owned copies of symbols matching a base or qualified name.
  if name notin snapshot.nameIndex:
    return
  for reference in snapshot.nameIndex[name]:
    result.add(snapshot.modules[reference.moduleIndex].symbols[reference.symbolIndex])

proc symbolsAt*(
    snapshot: SemanticSnapshot, uri: string, line, column: int32
): seq[SymbolInfo] =
  let key = uri & '\0' & $line & '\0' & $column
  if key notin snapshot.locationIndex:
    return
  for reference in snapshot.locationIndex[key]:
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
