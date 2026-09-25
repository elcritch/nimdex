## Versioned, validated persistence of owned per-head semantic records.

import std/[json, jsonutils, os, sha1, strutils, tables, tempfiles]

import ./compilerinputs
import ./semantic
import ./workspace

type
  CompilerDiagnosticSeverity* = enum
    cdsError
    cdsWarning
    cdsInformation
    cdsHint

  CompilerDiagnostic* = object
    sourcePath*: string
    sourceUri*: string
    line*: int32
    column*: int32
    hasLocation*: bool
    severity*: CompilerDiagnosticSeverity
    message*: string

  HeadAnalysis* = object ## Immutable after a successful head analysis.
    headPath*: string
    cachePath*: string
    reuseKey*: uint64
    inputPaths*: seq[string]
    inputFingerprint*: uint64
    overlayFingerprint*: uint64
    snapshot*: ref SemanticSnapshot
    diagnostics*: seq[CompilerDiagnostic]
    artifactPaths*: seq[string]

  ModuleRecord = object
    digest: string
    artifactPath: string

  HeadManifest = object
    version: int
    keyVersion: int
    inputVersion: int
    headPath: string
    reuseKey: uint64
    inputPaths: seq[string]
    inputFingerprint: uint64
    diagnostics: seq[CompilerDiagnostic]
    modules: seq[ModuleRecord]

  HeadCache* = object
    root: string
    modules: Table[string, ModuleSnapshot]
    written: Table[string, string]
    legacyInputs: InputFingerprints
    loadedModules*: int

const
  HeadCacheVersion* = 2
  HeadKeyVersion = 2
  HeadInputVersion = 2
  MaxRecordBytes = 64'i64 * 1024 * 1024
  MaxManifestBytes = 8'i64 * 1024 * 1024
  MaxHeadBytes = 256'i64 * 1024 * 1024

proc initHeadCache*(root: string): HeadCache =
  HeadCache(root: root / "semantic-v" & $HeadCacheVersion)

proc headManifestPath*(cachePath: string): string =
  cachePath / "analysis.json"

proc toJsonHook(module: ModuleSnapshot): JsonNode =
  result = newJObject()
  for name, value in fieldPairs(module):
    when name notin ["symbolData", "headFiles", "artifactPath"]:
      result[name] = toJson(value)
  result["symbols"] = toJson(module.symbols)

proc fromJsonHook(module: var ModuleSnapshot, node: JsonNode) =
  if node.kind != JObject:
    raise newException(ValueError, "invalid semantic record")
  for name, value in fieldPairs(module):
    when name notin ["symbolData", "headFiles", "artifactPath"]:
      if not node.hasKey(name):
        raise newException(ValueError, "missing semantic field: " & name)
      fromJson(value, node[name])
  if not node.hasKey("symbols") or node["symbols"].kind != JArray:
    raise newException(ValueError, "missing semantic symbols")
  module.setSymbols(node["symbols"].jsonTo(seq[SymbolInfo]))

proc readBounded(path: string, limit: int64): string =
  if getFileSize(path) > limit:
    raise newException(ValueError, "semantic cache exceeds size limit")
  result = readFile(path)
  if result.len.int64 > limit:
    raise newException(ValueError, "semantic cache exceeds size limit")

proc writeAtomic(path, text: string) =
  createDir(path.parentDir)
  let temporary = createTempFile(".analysis-", ".tmp", path.parentDir)
  try:
    try:
      temporary.cfile.write(text)
    finally:
      temporary.cfile.close()
    moveFile(temporary.path, path)
  finally:
    if fileExists(temporary.path):
      removeFile(temporary.path)

proc storeHead*(cache: var HeadCache, analysis: HeadAnalysis) =
  ## Publish the manifest last. An interrupted write cannot publish half a head.
  var manifest = HeadManifest(
    version: HeadCacheVersion,
    keyVersion: HeadKeyVersion,
    inputVersion: HeadInputVersion,
    headPath: analysis.headPath,
    reuseKey: analysis.reuseKey,
    inputPaths: analysis.inputPaths,
    inputFingerprint: analysis.inputFingerprint,
    diagnostics: analysis.diagnostics,
  )
  for module in analysis.snapshot[].modules:
    let key = module.artifactHash & ":" & $module.sourceTextHash
    var digest = cache.written.getOrDefault(key)
    if digest.len == 0:
      let data = $toJson(module)
      digest = $secureHash(data)
      # Rewrite on a fresh analysis so a damaged record can repair itself.
      writeAtomic(cache.root / (digest & ".json"), data)
      cache.written[key] = digest
    manifest.modules.add(
      ModuleRecord(digest: digest, artifactPath: module.artifactPath)
    )
  writeAtomic(headManifestPath(analysis.cachePath), $toJson(manifest))

proc restoreHead*(
    cache: var HeadCache,
    workspace: Workspace,
    head, cachePath: string,
    reuseKey: uint64,
    fingerprints: var InputFingerprints,
    analysis: var HeadAnalysis,
): bool =
  ## Invalid, old, missing or corrupt caches are ordinary cache misses.
  try:
    let manifestNode =
      parseJson(readBounded(headManifestPath(cachePath), MaxManifestBytes))
    let legacyKey = not manifestNode.hasKey("keyVersion")
    let legacyInput = not manifestNode.hasKey("inputVersion")
    # Older keys hashed the entire process environment. The cache directory
    # still fixes compiler and workspace configuration; validate saved inputs
    # before replacing that key with the stable one.
    if legacyKey:
      manifestNode["keyVersion"] = %1
    if legacyInput:
      manifestNode["inputVersion"] = %1
    var manifest = manifestNode.jsonTo(HeadManifest)
    if manifest.version != HeadCacheVersion or manifest.headPath != head or
        (not legacyKey and manifest.keyVersion != HeadKeyVersion) or
        (not legacyInput and manifest.inputVersion != HeadInputVersion) or
        (not legacyKey and manifest.reuseKey != reuseKey) or
        head notin manifest.inputPaths or manifest.modules.len == 0 or
        manifest.modules.len > 10000:
      return false
    let inputsMatch =
      if legacyInput:
        fingerprintInputsLegacy(manifest.inputPaths, cache.legacyInputs) ==
          manifest.inputFingerprint
      else:
        fingerprintInputs(manifest.inputPaths, fingerprints) == manifest.inputFingerprint
    if not inputsMatch:
      return false
    let currentInputFingerprint = fingerprintInputs(manifest.inputPaths, fingerprints)
    var restored = HeadAnalysis(
      headPath: head,
      cachePath: cachePath,
      reuseKey: reuseKey,
      inputPaths: manifest.inputPaths,
      inputFingerprint: currentInputFingerprint,
      diagnostics: manifest.diagnostics,
    )
    new(restored.snapshot)
    restored.snapshot[] = initSemanticSnapshot(
      workspace.projectId, workspace.configurationGeneration,
      workspace.configurationFingerprint,
    )
    var totalBytes = 0'i64
    for record in manifest.modules:
      if record.digest.len != 40 or record.digest.contains(AllChars - HexDigits):
        return false
      var module: ModuleSnapshot
      if record.digest in cache.modules:
        module = cache.modules[record.digest]
      else:
        let data = readBounded(cache.root / (record.digest & ".json"), MaxRecordBytes)
        totalBytes += data.len
        if totalBytes > MaxHeadBytes or $secureHash(data) != record.digest:
          return false
        module = parseJson(data).jsonTo(ModuleSnapshot)
        if module.sourcePath.len == 0 or module.sourcePath notin manifest.inputPaths or
            module.artifactHash.len == 0:
          return false
        cache.modules[record.digest] = module
        inc cache.loadedModules
      module.artifactPath = record.artifactPath
      restored.artifactPaths.add(record.artifactPath)
      restored.snapshot[].addModule(module)
    if not restored.snapshot[].containsModule(head):
      return false
    restored.snapshot[].recordHead(head)
    restored.snapshot[].compactHead()
    analysis = move(restored)
    if legacyKey or legacyInput:
      manifest.keyVersion = HeadKeyVersion
      manifest.inputVersion = HeadInputVersion
      manifest.reuseKey = reuseKey
      manifest.inputFingerprint = currentInputFingerprint
      try:
        writeAtomic(headManifestPath(cachePath), $toJson(manifest))
      except CatchableError:
        discard
    true
  except CatchableError:
    false
  except RangeDefect:
    # jsonutils checks enum ranges while decoding untrusted persisted records.
    false

proc forgetHead*(cachePath: string) =
  ## A failed rebuild must never leave a reusable success manifest behind.
  let path = headManifestPath(cachePath)
  if fileExists(path):
    removeFile(path)
