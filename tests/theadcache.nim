import std/[json, os, tables, times, unittest]

import nimdex/[compilerinputs, documents, headcache, semantic, workspace]

suite "owned semantic cache":
  test "restores graphs and symbols and rejects stale or damaged records":
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
      artifactHash: "artifact",
      sourcePath: source,
      sourceUri: documentUriFromPath(source),
      sourceTextHash: stableTextHash(readFile(source)),
      artifactPath: root / "main.s.bif",
    )
    module.setSymbols(
      @[
        SymbolInfo(
          name: "saved",
          key: "saved.main",
          modulePath: source,
          location: SourceLocation(
            valid: true,
            path: source,
            uri: module.sourceUri,
            line: 1,
            column: 5,
            sourceTextHash: module.sourceTextHash,
          ),
        )
      ]
    )
    var analysis = HeadAnalysis(
      headPath: source,
      cachePath: root / "cache/head",
      reuseKey: high(uint64),
      inputPaths: @[source],
      inputFingerprint: fingerprintInputs(@[source]),
    )
    new(analysis.snapshot)
    analysis.snapshot[] =
      initSemanticSnapshot(workspace.projectId, 0, workspace.configurationFingerprint)
    analysis.snapshot[].addModule(module)
    analysis.snapshot[].recordHead(source)
    var writer = initHeadCache(root / "cache")
    writer.storeHead(analysis)
    let manifestPath = headManifestPath(analysis.cachePath)
    let validManifest = readFile(manifestPath)
    var reader = initHeadCache(root / "cache")
    var fingerprints: InputFingerprints
    var restored: HeadAnalysis
    check reader.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, restored
    )
    check reader.loadedModules == 1
    check restored.snapshot[].findSymbols("saved").len == 1
    check restored.snapshot[].graph.headsFor(source) == @[source]
    check restored.snapshot[].findModule(source).sourceTextHash == module.sourceTextHash
    # The persisted semantic records are sufficient even without original BIFs.
    check not fileExists(module.artifactPath)
    setLastModificationTime(
      source, getLastModificationTime(source) + initDuration(seconds = 2)
    )
    fingerprints.clear()
    check reader.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, restored
    )

    var legacyManifest = parseJson(validManifest)
    legacyManifest.delete("keyVersion")
    legacyManifest.delete("inputVersion")
    legacyManifest["reuseKey"] = %0
    var legacyFingerprints: InputFingerprints
    legacyManifest["inputFingerprint"] =
      %fingerprintInputsLegacy(@[source], legacyFingerprints)
    writeFile(manifestPath, $legacyManifest)
    writeFile(source, "proc changed*() = discard\n")
    fingerprints.clear()
    check not reader.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, restored
    )
    writeFile(source, "proc saved*() = discard\n")
    # The legacy format also included the source mtime in its input digest.
    legacyFingerprints.clear()
    legacyManifest["inputFingerprint"] =
      %fingerprintInputsLegacy(@[source], legacyFingerprints)
    writeFile(manifestPath, $legacyManifest)
    reader = initHeadCache(root / "cache")
    fingerprints.clear()
    check reader.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, restored
    )
    check parseJson(readFile(manifestPath))["keyVersion"].getInt() == 2
    check parseJson(readFile(manifestPath))["inputVersion"].getInt() == 2
    check not reader.restoreHead(
      workspace, source, analysis.cachePath, 0'u64, fingerprints, restored
    )

    fingerprints.clear()
    writeFile(source, "proc changed*() = discard\n")
    check not reader.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, restored
    )
    writeFile(source, "proc saved*() = discard\n")
    analysis.inputFingerprint = fingerprintInputs(@[source])
    writer.storeHead(analysis)
    fingerprints.clear()

    var manifest = parseJson(readFile(manifestPath))
    let recordPath =
      root / "cache" / ("semantic-v" & $HeadCacheVersion) /
      (manifest["modules"][0]["digest"].getStr() & ".json")
    writeFile(recordPath, "{\"damaged\":true}")
    reader = initHeadCache(root / "cache")
    check not reader.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, restored
    )
    writer = initHeadCache(root / "cache")
    writer.storeHead(analysis)
    check reader.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, restored
    )
    manifest = parseJson(readFile(manifestPath))
    manifest["version"] = %999
    writeFile(manifestPath, $manifest)
    check not reader.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, restored
    )
    writeFile(manifestPath, "{")
    check not reader.restoreHead(
      workspace, source, analysis.cachePath, analysis.reuseKey, fingerprints, restored
    )
    writeFile(manifestPath, validManifest)
    forgetHead(analysis.cachePath)
    check not fileExists(manifestPath)
