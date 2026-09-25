## Safe, owned compatibility inspection for Binny BIF artifacts.
##
## This module is intentionally smaller than the future semantic index. It
## proves the artifact boundary without allowing Binny cursors, pools, or
## buffers to escape into the rest of Nimdex.

import std/[sets, tables]

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
    instantiatedFrom*: string
    typeId*: string ## Compiler type identity for named type declarations.
    raisesKnown*: bool ## An effect list exists; false is not an empty list.
    raisesTypes*: seq[string] ## Qualified exception symbols or compiler type identities.

  BinnyOccurrence* = object
    name*: string
    atCall*: bool ## Inline generic definition used as a call callee.
    location*: BinnyLocation

  BinnyArtifactReport* = object
    path*: string ## The artifact path passed to the inspector.
    status*: BinnyArtifactStatus ## Load and metadata outcome.
    sourcePath*: string ## The `modulesrc` path, when present.
    sourceFiles*: seq[string] ## Source filenames referenced by line metadata.
    imports*: seq[string] ## Resolved compiler module suffixes.
    includes*: seq[string] ## Resolved include paths.
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
  var positions = initHashSet[int]()
  for name, visibility, declaration in module.declarations:
    positions.incl(module.buf.cursorToPosition(declaration))
  var current = NoNifLineInfo
  var cursor = module.buf.beginRead()
  while cursor.hasMore:
    let info = cursor.rawLineInfo()
    if info.isValid:
      current = info
    let position = module.buf.cursorToPosition(cursor)
    if current.isValid and position in positions:
      result[position] = locationFromInfo(module, current)
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
  var seen = initHashSet[string]()
  var cursor = module.buf.beginRead()
  while cursor.hasMore:
    if cursor.kind == TagLit:
      let name = cursor.tagName()
      if not seen.containsOrIncl(name):
        result.add(name)
    cursor.inc()
  cursor.endRead()

proc collectDependencies(module: var BifModule, report: var BinnyArtifactReport) =
  ## Only direct module records describe dependency edges; strings in bodies
  ## and filename pools are not imports. Includes may contain several paths.
  var cursor = module.buf.beginRead()
  if cursor.kind != TagLit:
    cursor.endRead()
    return
  var child = cursor.childCursor()
  while child.hasMore:
    if child.kind == TagLit and child.tagName() in ["import", "include"]:
      let isImport = child.tagName() == "import"
      var value = child.childCursor()
      while value.hasMore:
        if value.kind == StrLit:
          let path = value.strVal()
          if isImport:
            if path notin report.imports:
              report.imports.add(path)
          elif path notin report.includes:
            report.includes.add(path)
        value.skip()
    child.skip()
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

proc childAt(node: Cursor, index: int): Cursor =
  if node.cursorIsNil or node.kind != TagLit:
    return
  var child = node.childCursor()
  var current = 0
  while child.hasMore:
    if current == index:
      return child
    inc current
    child.skip()

proc symbolIdentity(node: Cursor): string =
  if not node.cursorIsNil:
    if node.kind in {Symbol, SymbolDef}:
      return node.symName()
    if node.tagIs("td"):
      return symbolIdentity(node.childAt(0))

proc resolveNode(node: Cursor, definitions: Table[string, Cursor]): Cursor =
  result = node
  if not node.cursorIsNil and node.kind == Symbol:
    result = definitions.getOrDefault(node.symName())

proc extractDeclaration(
    module: var BifModule,
    node: Cursor,
    visibility: BinnyVisibility,
    locations: Table[int, BinnyLocation],
    definitions: Table[string, Cursor],
): BinnyDeclaration =
  result.name = symbolIdentity(node.childAt(0))
  result.tag = node.tagName()
  result.visibility = visibility
  result.location = module.declarationLocation(node, locations)
  if not node.tagIs("sd"):
    return
  let kind = node.childAt(2)
  if kind.cursorIsNil or kind.kind != TagLit:
    return
  result.tag = kind.tagName()
  result.instantiatedFrom = symbolIdentity(node.childAt(17))
  let typ = node.childAt(9)
  if result.tag == "type":
    result.typeId = symbolIdentity(typ)
  if result.tag notin ["proc", "func", "method", "iterator", "converter"]:
    return
  let definition = resolveNode(typ, definitions)
  if not definition.tagIs("td"):
    return
  # ast2nif's td[9] is PType.n. FormalParams has flags, return type,
  # then the six-entry effect list. Its first AST child is exceptionEffects.
  let params = definition.childAt(9)
  if not params.tagIs("formalparams"):
    return
  let effects = params.childAt(2)
  if not effects.tagIs("arglist"):
    return
  let exceptions = effects.childAt(2)
  if not (exceptions.tagIs("bracket") or exceptions.tagIs("arglist")):
    return
  result.raisesKnown = true
  var effect = exceptions.childAt(2)
  while not effect.cursorIsNil and effect.hasMore:
    let identity =
      if effect.kind == Symbol:
        effect.symName()
      elif effect.kind == TagLit:
        symbolIdentity(effect.childAt(1))
      else:
        ""
    if identity.len == 0:
      result.raisesKnown = false
    elif identity notin result.raisesTypes:
      result.raisesTypes.add(identity)
    effect.skip()

proc inspectLoadedArtifact(module: var BifModule, path: string): BinnyArtifactReport =
  result.path = path
  result.sourcePath = module.extractSourcePath()
  module.collectDependencies(result)
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

  var definitions: Table[string, Cursor]
  var cursor = module.buf.beginRead()
  while cursor.hasMore:
    if cursor.tagIs("td"):
      definitions[symbolIdentity(cursor.childAt(0))] = cursor
    cursor.inc()
  for name, visibility, declaration in module.declarations:
    # Anonymous compiler type records have no source identifier. Keep their
    # cursors only while decoding effects; they are not language symbols.
    if declaration.tagIs("td"):
      continue
    result.declarations.add module.extractDeclaration(
      declaration,
      (if visibility == ivExported: bvisExported else: bvisHidden),
      effectiveLocations,
      definitions,
    )
  # Local variables/parameters are not necessarily in the global BIF index.
  var seen = initHashSet[string]()
  for declaration in result.declarations:
    seen.incl(declaration.name)
  cursor.endRead()
  cursor = module.buf.beginRead()
  while cursor.hasMore:
    if cursor.tagIs("sd"):
      let name = symbolIdentity(cursor.childAt(0))
      if name.len > 0 and not seen.containsOrIncl(name):
        result.declarations.add module.extractDeclaration(
          cursor, bvisHidden, effectiveLocations, definitions
        )
    cursor.inc()
  cursor.endRead()

  if result.sourcePath.len == 0:
    result.status = basMetadataIncomplete
    result.metadataError = "BIF has no modulesrc source path"
  else:
    result.status = basReady

proc inspectBinnyArtifact*(
    path: string, limits = DefaultBinnyLoadLimits
): BinnyArtifactReport =
  ## Safely load and summarize one BIF without exposing Binny-owned storage.
  trace "Opening BIF artifact",
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
    trace "Opened BIF artifact",
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

proc readBinnyOccurrences*(path, sourcePath: string): seq[BinnyOccurrence] =
  ## Load uses only for a queried source. Keep borrowed cursors inside this call.
  ## Raw use positions are required: inheriting a prior AST node's location can
  ## silently turn a generated use into an unrelated source token.
  var module: BifModule
  var failure: BifLoadFailure
  if not tryLoad(path, module, failure, DefaultBinnyLoadLimits):
    return
  var cursor = module.buf.beginRead()
  while cursor.hasMore:
    if cursor.tagIs("call"):
      let callee = cursor.childAt(2)
      if callee.tagIs("sd"):
        let location = module.locationFromInfo(cursor.rawLineInfo())
        if location.valid and location.file == sourcePath:
          result.add BinnyOccurrence(
            name: symbolIdentity(callee.childAt(0)), location: location, atCall: true
          )
    if cursor.kind == Symbol:
      let location = module.locationFromInfo(cursor.rawLineInfo())
      if location.valid and location.file == sourcePath:
        result.add BinnyOccurrence(name: cursor.symName(), location: location)
        if result.len >= 100_000:
          break
    cursor.inc()
  cursor.endRead()
