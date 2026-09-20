import std/[assertions, os, strutils, tempfiles, unittest]

import binny/bif
import binny/bif_safe as bifSafe
import nimdex/binnycompat

const
  FixtureRoot = currentSourcePath.parentDir / "fixtures/binny_phase0"
  FixtureMain = FixtureRoot / "main.nim"
  SampleSource = "/workspace/phase0/main.nim"

proc tempBifPath(): string =
  let (file, path) = createTempFile("nimdex-binny-phase0-", ".bif")
  file.close()
  path

proc writeSampleBif(path: string, includeSourcePath = true) =
  var buffer = createTokenBuf()
  let
    moduleTag = buffer.tags.registerTag("module")
    sourceTag = buffer.tags.registerTag("modulesrc")
    procTag = buffer.tags.registerTag("proc")
    typeTag = buffer.tags.registerTag("type")
    sourceFile = buffer.pool.filenames.getOrIncl(SampleSource)

  buffer.openTag(moduleTag)
  buffer.appendLineInfo(sourceFile, 1, 0)
  if includeSourcePath:
    buffer.buildTree sourceTag:
      buffer.addStrLit(SampleSource)

  buffer.openTag(procTag)
  buffer.appendLineInfo(sourceFile, 12, 4)
  buffer.addSymDef("phase0.sample.exported")
  buffer.closeTag()

  buffer.openTag(typeTag)
  buffer.appendLineInfo(sourceFile, 24, 2)
  buffer.addSymDef("phase0.sample.hidden")
  buffer.addDotToken()
  buffer.closeTag()
  buffer.closeTag()
  buffer.store(path)

proc findDeclaration(report: BinnyArtifactReport, name: string): BinnyDeclaration =
  for declaration in report.declarations:
    if declaration.name == name:
      return declaration
  raise newException(KeyError, "missing declaration: " & name)

suite "Nimdex Binny phase 0 compatibility":
  test "keeps the real compiler fixture reproducible":
    doAssert fileExists(FixtureMain)
    let source = readFile(FixtureMain)
    doAssert "exportedRoutine*" in source
    doAssert "hiddenRoutine" in source
    doAssert "genericRoutine*" in source
    doAssert "phase0Macro*" in source
    doAssert "localHelper" in source
    doAssert "café" in source
    doAssert "longSourceLine*" in source
    var hasLongLine = false
    for line in source.splitLines:
      if line.len > 1023:
        hasLongLine = true
    doAssert hasLongLine

  test "summarizes a valid BIF through the safe loader":
    let path = tempBifPath()
    defer:
      if fileExists(path):
        removeFile(path)
    writeSampleBif(path)

    let report = inspectBinnyArtifact(path)
    doAssert report.isReady()
    doAssert report.sourcePath == SampleSource
    doAssert "module" in report.tags
    doAssert "modulesrc" in report.tags
    doAssert "proc" in report.tags
    doAssert "type" in report.tags
    doAssert report.declarations.len == 2

    let exported = report.findDeclaration("phase0.sample.exported")
    doAssert exported.visibility == bvisExported
    doAssert exported.tag == "proc"
    doAssert exported.location.valid
    doAssert exported.location.file == SampleSource
    doAssert exported.location.line == 12
    doAssert exported.location.column == 4

    let hidden = report.findDeclaration("phase0.sample.hidden")
    doAssert hidden.visibility == bvisHidden
    doAssert hidden.tag == "type"
    doAssert hidden.location.line == 24
    doAssert hidden.location.column == 2

  test "reports missing semantic metadata separately from load failure":
    let path = tempBifPath()
    defer:
      if fileExists(path):
        removeFile(path)
    writeSampleBif(path, includeSourcePath = false)

    let report = inspectBinnyArtifact(path)
    doAssert report.status == basMetadataIncomplete
    doAssert not report.isReady()
    doAssert report.metadataError == "BIF has no modulesrc source path"

  test "returns structured failures for malformed BIF input":
    let path = tempBifPath()
    defer:
      if fileExists(path):
        removeFile(path)
    writeFile(path, "NOTBIF!!")

    let report = inspectBinnyArtifact(path)
    doAssert report.status == basLoadFailed
    doAssert report.failure.kind == bekInvalidMagic
    doAssert report.failure.path == path

  test "classifies missing, truncated, and incompatible BIF files":
    let missingPath = tempBifPath()
    removeFile(missingPath)
    let missing = inspectBinnyArtifact(missingPath)
    doAssert missing.status == basLoadFailed
    doAssert missing.failure.kind == bekIo

    let truncatedPath = tempBifPath()
    defer:
      if fileExists(truncatedPath):
        removeFile(truncatedPath)
    writeSampleBif(truncatedPath)
    let encoded = readFile(truncatedPath)
    writeFile(truncatedPath, encoded[0 ..< min(encoded.len, 16)])
    let truncated = inspectBinnyArtifact(truncatedPath)
    doAssert truncated.status == basLoadFailed
    doAssert truncated.failure.kind == bekTruncated

    let incompatiblePath = tempBifPath()
    defer:
      if fileExists(incompatiblePath):
        removeFile(incompatiblePath)
    writeFile(incompatiblePath, "NIFBIN" & "\0\4")
    let incompatible = inspectBinnyArtifact(incompatiblePath)
    doAssert incompatible.status == basLoadFailed
    doAssert incompatible.failure.kind == bekUnsupportedFormat

  test "tryLoad preserves an existing module when a refresh fails":
    let validPath = tempBifPath()
    let invalidPath = tempBifPath()
    defer:
      if fileExists(validPath):
        removeFile(validPath)
      if fileExists(invalidPath):
        removeFile(invalidPath)
    writeSampleBif(validPath)
    writeFile(invalidPath, "NOTBIF!!")

    var module = bifSafe.load(validPath)
    var failure: BifLoadFailure
    doAssert not bifSafe.tryLoad(invalidPath, module, failure)
    doAssert failure.kind == bekInvalidMagic
    doAssert module.findDeclaration("phase0.sample.exported").kind == TagLit

  test "enforces explicit daemon-sized load limits":
    let path = tempBifPath()
    defer:
      if fileExists(path):
        removeFile(path)
    writeSampleBif(path)

    var limits = DefaultBinnyLoadLimits
    limits.maxFileBytes = 1
    let report = inspectBinnyArtifact(path, limits)
    doAssert report.status == basLoadFailed
    doAssert report.failure.kind == bekLimitExceeded
