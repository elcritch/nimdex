import std/[assertions, os, unittest]

import binny/bif

import nimdex/bifindex
import nimdex/documents
import nimdex/workspace

const SampleSourceName = "main.nim"

proc writeSampleBif(path, sourcePath: string, includeSourcePath = true) =
  var buffer = createTokenBuf()
  let
    moduleTag = buffer.tags.registerTag("module")
    sourceTag = buffer.tags.registerTag("modulesrc")
    declarationTag = buffer.tags.registerTag("sd")
    sourceFile = buffer.pool.filenames.getOrIncl(sourcePath)

  buffer.openTag(moduleTag)
  buffer.appendLineInfo(sourceFile, 1, 0)
  if includeSourcePath:
    buffer.buildTree sourceTag:
      buffer.addStrLit(sourcePath)

  buffer.openTag(declarationTag)
  buffer.appendLineInfo(sourceFile, 2, 1)
  buffer.addSymDef("exported.0.testmod")
  buffer.closeTag()

  buffer.openTag(declarationTag)
  buffer.appendLineInfo(sourceFile, 4, 1)
  buffer.addSymDef("hidden.0.testmod")
  buffer.addDotToken()
  buffer.closeTag()
  buffer.closeTag()
  buffer.store(path)

proc makeArtifactRoot(): string =
  result = getTempDir() / ("nimdex-bifindex-" & $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)
  createDir(result / "nested")

suite "Nimdex offline BIF index":
  test "discovers semantic BIFs without exposing Binny storage":
    let root = makeArtifactRoot()
    defer:
      if dirExists(root):
        removeDir(root)
    let sourcePath = normalizeDocumentPath(root / "src" / SampleSourceName)
    createDir(root / "src")
    let validPath = root / "nested" / "main.s.bif"
    let invalidPath = root / "bad.s.bif"
    writeSampleBif(validPath, sourcePath)
    writeFile(invalidPath, "NOTBIF!!")

    let artifacts = discoverBifArtifacts(@[root, root / "nested"])
    doAssert artifacts.len == 2
    doAssert artifacts[0] == invalidPath
    doAssert artifacts[1] == validPath

    let workspace = initWorkspace(
      documentUriFromPath(root), artifactRoots = @[root], configurationGeneration = 8
    )
    var options = DefaultBifIndexOptions
    options.workerCount = 2
    let index = buildBifIndex(workspace, options = options)
    doAssert index.projectId == workspace.projectId
    doAssert index.configurationGeneration == 8
    doAssert index.moduleCount() == 1
    doAssert index.failureCount() == 1
    doAssert index.containsModule(sourcePath)

    let exported = index.findSymbols("exported")
    doAssert exported.len == 1
    doAssert exported[0].visibility == svExported
    doAssert exported[0].qualifiedName == "exported.0.testmod"
    doAssert exported[0].location.valid
    doAssert exported[0].location.path == sourcePath
    doAssert exported[0].location.line == 2
    doAssert exported[0].location.column == 1

    let hidden = index.findSymbols("hidden")
    doAssert hidden.len == 1
    doAssert hidden[0].visibility == svHidden

    let atLocation = index.symbolsAt(documentUriFromPath(sourcePath), 2, 1)
    doAssert atLocation.len == 1
    doAssert atLocation[0].name == "exported"

    let failure = index.failures[0]
    doAssert failure.kind == afInvalidMagic
    doAssert failure.artifactPath == invalidPath

  test "reports metadata failures while retaining valid modules":
    let root = makeArtifactRoot()
    defer:
      if dirExists(root):
        removeDir(root)
    let sourcePath = normalizeDocumentPath(root / "source.nim")
    writeSampleBif(root / "valid.s.bif", sourcePath)
    writeSampleBif(root / "incomplete.s.bif", sourcePath, includeSourcePath = false)

    let workspace = initWorkspace(documentUriFromPath(root))
    var options = DefaultBifIndexOptions
    options.workerCount = 2
    let index = buildBifIndex(workspace, @[root], options)
    doAssert index.moduleCount() == 1
    doAssert index.failureCount() == 1
    doAssert index.failures[0].kind == afMetadataIncomplete
