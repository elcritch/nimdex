## Persist head inputs and BIF references, without duplicating semantic data.

import std/[json, jsonutils, os, strutils, tables, tempfiles]

import ./bifindex
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
    headPath: string
    reuseKey: uint64
    inputPaths: seq[string]
    inputFingerprint: uint64
    diagnostics: seq[CompilerDiagnostic]
    modules: seq[ModuleRecord]

  HeadCache* = object

const
  HeadCacheVersion* = 3
  MaxManifestBytes = 8'i64 * 1024 * 1024

proc initHeadCache*(root: string): HeadCache =
  discard root
  HeadCache()

proc headManifestPath*(cachePath: string): string =
  cachePath / "analysis.json"

proc readBounded(path: string, limit: int64): string =
  if getFileSize(path) > limit:
    raise newException(ValueError, "head manifest exceeds size limit")
  result = readFile(path)
  if result.len.int64 > limit:
    raise newException(ValueError, "head manifest exceeds size limit")

proc completedHeadModuleCount*(cachePath, head: string): int =
  ## The manifest is published only after a successful head analysis.
  try:
    let manifest = parseJson(readBounded(headManifestPath(cachePath), MaxManifestBytes))
    if manifest.kind == JObject and manifest.hasKey("version") and
        manifest["version"].getInt() == HeadCacheVersion and manifest.hasKey("headPath") and
        manifest["headPath"].getStr() == head and manifest.hasKey("modules") and
        manifest["modules"].kind == JArray and manifest["modules"].len <= 10000:
      result = manifest["modules"].len
  except CatchableError:
    discard

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
  ## Publish references only after a successful head; BIFs hold the symbols.
  var manifest = HeadManifest(
    version: HeadCacheVersion,
    headPath: analysis.headPath,
    reuseKey: analysis.reuseKey,
    inputPaths: analysis.inputPaths,
    inputFingerprint: analysis.inputFingerprint,
    diagnostics: analysis.diagnostics,
  )
  for module in analysis.snapshot[].modules:
    manifest.modules.add(
      ModuleRecord(digest: module.artifactHash, artifactPath: module.artifactPath)
    )
  writeAtomic(headManifestPath(analysis.cachePath), $toJson(manifest))

proc restoreHead*(
    cache: var HeadCache,
    workspace: Workspace,
    head, cachePath: string,
    reuseKey: uint64,
    fingerprints: var InputFingerprints,
    artifacts: var BifReuseCache,
    analysis: var HeadAnalysis,
): bool =
  ## Invalid, old, missing or corrupt manifests and BIFs are cache misses.
  try:
    let manifest = parseJson(readBounded(headManifestPath(cachePath), MaxManifestBytes))
      .jsonTo(HeadManifest)
    if manifest.version != HeadCacheVersion or manifest.headPath != head or
        manifest.reuseKey != reuseKey or head notin manifest.inputPaths or
        manifest.modules.len == 0 or manifest.modules.len > 10000 or
        fingerprintInputs(manifest.inputPaths, fingerprints) != manifest.inputFingerprint:
      return false
    var paths: seq[string]
    var digests: Table[string, string]
    for record in manifest.modules:
      if record.digest.len != 40 or record.digest.contains(AllChars - HexDigits) or
          not fileExists(record.artifactPath) or record.artifactPath in digests:
        return false
      paths.add(record.artifactPath)
      digests[record.artifactPath] = record.digest
    var snapshot = buildBifIndexCached(workspace, artifacts, paths)
    if snapshot.failureCount() > 0 or snapshot.moduleCount() != paths.len or
        not snapshot.containsModule(head):
      return false
    for module in snapshot.modules:
      if module.sourcePath.len == 0 or module.sourcePath notin manifest.inputPaths or
          module.artifactHash != digests.getOrDefault(module.artifactPath):
        return false
    snapshot.recordHead(head)
    snapshot.compactHead()
    var restored = HeadAnalysis(
      headPath: head,
      cachePath: cachePath,
      reuseKey: reuseKey,
      inputPaths: manifest.inputPaths,
      inputFingerprint: manifest.inputFingerprint,
      diagnostics: manifest.diagnostics,
      artifactPaths: paths,
    )
    new(restored.snapshot)
    restored.snapshot[] = move(snapshot)
    analysis = move(restored)
    true
  except CatchableError, RangeDefect:
    false

proc forgetHead*(cachePath: string) =
  ## A failed rebuild must never leave a reusable success manifest behind.
  let path = headManifestPath(cachePath)
  if fileExists(path):
    removeFile(path)
