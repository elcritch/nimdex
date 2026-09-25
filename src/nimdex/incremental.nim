## Discover the live semantic closure of a completed `nim track` build.
## Compiler build rules map sources to artifacts; checked BIF sidecars supply
## resolved imports, including macro-generated imports. No compiler hashing or
## symbol pool identities are reproduced here.

import std/[algorithm, os, sets, strutils, tables]

import binny/bif_safe
import binny/native_dynlib/nif/nifcoreparse

import ./documents

const DependencyLimits = BifLoadLimits(
  maxFileBytes: 8 * 1024 * 1024,
  maxTokens: 1024 * 1024,
  maxPoolEntries: 100000,
  maxStringBytes: 4 * 1024 * 1024,
  maxIndexEntries: 100000,
)

proc readBuildMetadata(path: string): TokenBuf =
  if not fileExists(path) or getFileSize(path) > 16 * 1024 * 1024:
    raise newException(ValueError, "missing or oversized incremental metadata: " & path)
  try:
    result = parseFromFile(path)
  except AssertionDefect, IndexDefect, RangeDefect:
    raise newException(ValueError, "invalid incremental metadata: " & path)
  if result.len == 0:
    raise newException(ValueError, "empty incremental metadata: " & path)

proc incrementalConfigurationInputs*(cachePath: string): seq[string] =
  ## IC replays precompiled configuration and may omit ordinary config hints.
  var config = readBuildMetadata(cachePath / "ic_config.cfg.nif")
  var cursor = config.beginRead()
  defer:
    cursor.endRead()
  let sources = cursor.findChildTag("sources")
  if sources.cursorIsNil:
    raise newException(ValueError, "incremental config has no source metadata")
  var child = sources.childCursor()
  while child.hasMore:
    if child.kind != StrLit:
      raise newException(ValueError, "invalid incremental config source")
    result.add(normalizeDocumentPath(child.strVal()))
    child.skip()

proc resolvedImports(path: string): seq[string] =
  var module: BifModule
  var failure: BifLoadFailure
  if not tryLoad(path, module, failure, DependencyLimits):
    raise newException(
      ValueError,
      "invalid incremental dependency artifact: " & path & ": " & failure.message,
    )
  var cursor = module.buf.beginRead()
  defer:
    cursor.endRead()
  if cursor.kind != TagLit or cursor.tagName() != "semdeps":
    raise newException(ValueError, "missing semdeps metadata: " & path)
  var child = cursor.childCursor()
  while child.hasMore:
    if child.kind != StrLit:
      raise newException(ValueError, "invalid semdeps entry: " & path)
    result.add(normalizeDocumentPath(child.strVal()))
    child.skip()

proc incrementalArtifacts*(cachePath, head: string): seq[string] =
  ## Return only artifacts reachable from the actual head and implicit system
  ## root. Old files remain available to the compiler but never enter the index.
  var buildFile = ""
  for path in walkFiles(cachePath / "*.frontend.build.nif"):
    if buildFile.len > 0:
      raise newException(ValueError, "multiple incremental build graphs: " & cachePath)
    buildFile = path
  if buildFile.len == 0 or getFileSize(buildFile) > 16 * 1024 * 1024:
    raise newException(ValueError, "missing or oversized incremental build graph")

  var artifacts = initTable[string, string]()
  var pending = @[normalizeDocumentPath(head)]
  var build = readBuildMetadata(buildFile)
  var cursor = build.beginRead()
  defer:
    cursor.endRead()
  if cursor.kind != TagLit or cursor.tagName() != "stmts":
    raise newException(ValueError, "invalid incremental build graph: " & buildFile)
  var rule = cursor.childCursor()
  while rule.hasMore:
    if rule.kind == TagLit and rule.tagName() == "do":
      var field = rule.childCursor()
      let command =
        if field.kind == Ident:
          field.strVal()
        else:
          ""
      var source, parsed: string
      while field.hasMore:
        if field.kind == TagLit and field.tagName() in ["input", "output"]:
          let value = field.childCursor()
          if value.kind == StrLit:
            let path = value.strVal()
            if field.tagName() == "input" and source.len == 0 and path.endsWith(".nim"):
              source = normalizeDocumentPath(path)
            elif field.tagName() == "output" and path.endsWith(".p.nif"):
              parsed = normalizeDocumentPath(path)
        field.skip()
      if command == "nifler" and source.len > 0 and parsed.len > 0:
        let artifact = parsed[0 ..< parsed.len - ".p.nif".len] & ".s.bif"
        if artifact.parentDir != normalizeDocumentPath(cachePath):
          raise newException(ValueError, "incremental output is outside its cache")
        artifacts[source] = artifact
      elif command == "nim_m" and source.extractFilename() == "system.nim":
        pending.add(source)
    rule.skip()

  var seen = initHashSet[string]()
  while pending.len > 0:
    let source = pending.pop()
    if not seen.containsOrIncl(source):
      if seen.len > 10000:
        raise newException(ValueError, "incremental module count exceeds limit")
      if source notin artifacts or not fileExists(artifacts[source]):
        raise newException(
          ValueError, "missing incremental semantic artifact for " & source
        )
      let artifact = artifacts[source]
      result.add(artifact)
      let deps = artifact[0 ..< artifact.len - ".s.bif".len] & ".s.deps.bif"
      pending.add(resolvedImports(deps))
  result.sort()
