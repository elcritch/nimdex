import std/[json, os, strutils, unittest]

import nimdex/[bifindex, compilerinputs, documents, headcache, semantic, workspace]

suite "head cache manifests":
  test "stores references without semantic copies and rejects missing artifacts":
    let root = normalizeDocumentPath(
      getTempDir() / ("nimdex-head-cache-" & $getCurrentProcessId())
    )
    createDir(root)
    defer:
      removeDir(root)
    let source = root / "main.nim"
    writeFile(source, "proc saved*() = discard\n")
    let workspace = initWorkspace(documentUriFromPath(root), entryPoints = @[source])
    var module = ModuleSnapshot(
      moduleId: "main",
      artifactHash: "0123456789ABCDEF0123456789ABCDEF01234567",
      sourcePath: source,
      sourceUri: documentUriFromPath(source),
      sourceTextHash: stableTextHash(readFile(source)),
      artifactPath: root / "missing.s.bif",
    )
    module.setSymbols(
      @[SymbolInfo(name: "saved", key: "saved.main", modulePath: source)]
    )
    var analysis = HeadAnalysis(
      headPath: source,
      cachePath: root / "head",
      reuseKey: high(uint64),
      inputPaths: @[source],
      inputFingerprint: fingerprintInputs(@[source]),
    )
    new(analysis.snapshot)
    analysis.snapshot[] =
      initSemanticSnapshot(workspace.projectId, 0, workspace.configurationFingerprint)
    analysis.snapshot[].addModule(module)
    analysis.snapshot[].recordHead(source)
    var cache = initHeadCache(root)
    check completedHeadModuleCount(analysis.cachePath, source) == 0
    cache.storeHead(analysis)
    check completedHeadModuleCount(analysis.cachePath, source) == 1
    check completedHeadModuleCount(analysis.cachePath, root / "other.nim") == 0
    check not dirExists(root / "semantic-v3")
    let manifestPath = headManifestPath(analysis.cachePath)
    let manifest = parseJson(readFile(manifestPath))
    check manifest["modules"].len == 1
    check manifest["modules"][0]["artifactPath"].getStr() == module.artifactPath
    check not readFile(manifestPath).contains("saved.main")
    var fingerprints: InputFingerprints
    var artifacts: BifReuseCache
    var restored: HeadAnalysis
    check not cache.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, artifacts,
      restored,
    )
    writeFile(manifestPath, "{")
    check completedHeadModuleCount(analysis.cachePath, source) == 0
    check not cache.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, artifacts,
      restored,
    )
    forgetHead(analysis.cachePath)
    check not fileExists(manifestPath)
