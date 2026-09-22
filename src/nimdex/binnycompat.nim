## Safe, owned compatibility inspection for Binny BIF artifacts.
##
## This module is intentionally smaller than the future semantic index. It
## proves the artifact boundary without allowing Binny cursors, pools, or
## buffers to escape into the rest of Nimdex.

import std/tables

import binny/bif_safe
import chronicles

type
  BinnyArtifactStatus* = enum
    basReady ## The binary and the minimum metadata were accepted.
    basLoadFailed ## The BIF could not be safely loaded.
    basMetadataIncomplete ## The BIF loaded but lacks required phase-0 metadata.

  BinnyVisibility* = enum
    bvisHidden ## The declaration is not exported from its module.
    bvisExported ## The declaration is exported from its module.

  BinnyLocation* = object
    valid*: bool ## Whether the compiler supplied a source location.
    file*: string ## The source file recorded by the compiler.
    line*: int32 ## The raw compiler line value; conversion is a later phase.
    column*: int32 ## The raw compiler column value; conversion is a later phase.

  BinnyDeclaration* = object
    name*: string ## The compiler-qualified declaration name.
    tag*: string ## The enclosing BIF tag, usually `sd` or `td` in compiler output.
    visibility*: BinnyVisibility ## Whether the declaration was exported.
    location*: BinnyLocation ## The best location available in the artifact.

  BinnyArtifactReport* = object
    path*: string ## The artifact path passed to the inspector.
    status*: BinnyArtifactStatus ## Load and metadata outcome.
    sourcePath*: string ## The `modulesrc` path, when present.
    sourceFiles*: seq[string] ## Source filenames referenced by line metadata.
    tokenCount*: int ## Number of raw NIF tokens in the BIF.
    tagCount*: int ## Number of interned tag names.
    stringCount*: int ## Number of interned string literals.
    symbolCount*: int ## Number of interned symbols.
    filenameCount*: int ## Number of interned source filenames.
    tags*: seq[string] ## Distinct tags observed while traversing the artifact.
    declarations*: seq[BinnyDeclaration] ## Owned copies of indexed declarations.
    failure*: BifLoadFailure ## Structured safe-loader failure, when applicable.
    metadataError*: string ## A semantic metadata problem after binary loading.

const
  ## Limits suitable for an initial long-lived language-server probe. They are
  ## deliberately smaller than Binny's one-gigabyte default file limit.
  DefaultBinnyLoadLimits* = BifLoadLimits(
    maxFileBytes: 256'i64 * 1024 * 1024,
    maxTokens: 32 * 1024 * 1024,
    maxPoolEntries: 1 * 1024 * 1024,
    maxStringBytes: 32 * 1024 * 1024,
    maxIndexEntries: 4 * 1024 * 1024,
  )

proc locationFromInfo(module: var BifModule, info: NifLineInfo): BinnyLocation =
  if not info.isValid:
    return

  result.valid = true
  result.line = info.line
  result.column = info.col
  if info.file.isValid:
    result.file = module.buf.pool.filenames[info.file]

proc collectEffectiveLocations(module: var BifModule): Table[int, BinnyLocation] =
  ## Build a phase-0 position map while carrying sparse line information.
  ##
  ## BIF stores line information only when it changes. This flat walk is
  ## intentionally an evidence-oriented approximation: later semantic code
  ## must validate parent-relative locations against real compiler fixtures.
  var current = NoNifLineInfo
  var cursor = module.buf.beginRead()
  while cursor.hasMore:
    let info = cursor.rawLineInfo()
    if info.isValid:
      current = info
    if current.isValid:
      result[module.buf.cursorToPosition(cursor)] = locationFromInfo(module, current)
    cursor.inc()
  cursor.endRead()

proc extractSourcePath(module: var BifModule): string =
  var cursor = module.buf.beginRead()
  let sourceNode = cursor.findDescendantTag("modulesrc")
  if not sourceNode.cursorIsNil:
    let source = sourceNode.findChildKind(StrLit)
    if not source.cursorIsNil:
      result = source.strVal()
  cursor.endRead()

proc collectTags(module: var BifModule): seq[string] =
  var cursor = module.buf.beginRead()
  while cursor.hasMore:
    if cursor.kind == TagLit:
      let name = cursor.tagName()
      if name notin result:
        result.add(name)
    cursor.inc()
  cursor.endRead()

proc declarationLocation(
    module: var BifModule,
    declaration: Cursor,
    effectiveLocations: Table[int, BinnyLocation],
): BinnyLocation =
  result = locationFromInfo(module, declaration.rawLineInfo())
  if not result.valid:
    let position = module.buf.cursorToPosition(declaration)
    if position in effectiveLocations:
      result = effectiveLocations[position]

proc inspectLoadedArtifact(module: var BifModule, path: string): BinnyArtifactReport =
  result.path = path
  result.sourcePath = module.extractSourcePath()
  result.tokenCount = module.buf.len()
  result.tagCount = module.buf.tags.tags.len
  result.stringCount = module.buf.pool.strings.len
  result.symbolCount = module.buf.pool.syms.len
  result.filenameCount = module.buf.pool.filenames.len
  if result.filenameCount > 0:
    for index in 1 .. result.filenameCount:
      result.sourceFiles.add(module.buf.pool.filenames[FileId(index)])
  result.tags = module.collectTags()
  let effectiveLocations = module.collectEffectiveLocations()

  for name, visibility, declaration in module.declarations:
    result.declarations.add BinnyDeclaration(
      name: name,
      tag: declaration.tagName(),
      visibility: if visibility == ivExported: bvisExported else: bvisHidden,
      location: module.declarationLocation(declaration, effectiveLocations),
    )

  if result.sourcePath.len == 0:
    result.status = basMetadataIncomplete
    result.metadataError = "BIF has no modulesrc source path"
  else:
    result.status = basReady

proc inspectBinnyArtifact*(
    path: string, limits = DefaultBinnyLoadLimits
): BinnyArtifactReport =
  ## Safely load and summarize one BIF without exposing Binny-owned storage.
  debug "Opening BIF artifact",
    artifactPath = path,
    maxFileBytes = limits.maxFileBytes,
    maxTokens = limits.maxTokens,
    maxPoolEntries = limits.maxPoolEntries,
    maxStringBytes = limits.maxStringBytes,
    maxIndexEntries = limits.maxIndexEntries
  result.path = path
  var module: BifModule
  var failure: BifLoadFailure
  if not tryLoad(path, module, failure, limits):
    result.status = basLoadFailed
    result.failure = failure
    warn "Failed to load BIF artifact",
      artifactPath = path, failureKind = $failure.kind, failure = failure.message
    return

  result = inspectLoadedArtifact(module, path)
  if result.status == basReady:
    debug "Opened BIF artifact",
      artifactPath = result.path,
      sourcePath = result.sourcePath,
      tokenCount = result.tokenCount,
      declarationCount = result.declarations.len,
      tagCount = result.tagCount,
      stringCount = result.stringCount,
      symbolPoolCount = result.symbolCount,
      filenameCount = result.filenameCount
  else:
    warn "Loaded BIF artifact with incomplete metadata",
      artifactPath = result.path,
      sourcePath = result.sourcePath,
      metadataError = result.metadataError

proc isReady*(report: BinnyArtifactReport): bool =
  ## Return whether the artifact passed both binary and phase-0 metadata checks.
  report.status == basReady
