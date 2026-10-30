import
  std/[algorithm, json, options, os, sha1, strutils, tables, tempfiles, times, unittest]

import nimdex/[compiler, documents, headcache, incremental, lsp, semantic, workspace]
import sigils/rpcs/jsonrpc

const RepositoryRoot = currentSourcePath.parentDir.parentDir
let capabilities = probeCompiler()

proc requestFor(root, head: string, frontend = cfTrack): CompilerRefreshRequest =
  CompilerRefreshRequest(
    workspace: initWorkspace(
      documentUriFromPath(root),
      entryPoints = @[head],
      importPaths = @[root],
      cacheRoot = root / ".nimdex",
      compilerFrontend = frontend,
    ),
    capabilities: capabilities,
  )

proc artifactFor(refresh: CompilerRefreshResult, source: string): string =
  for module in refresh.snapshot.modules:
    if module.sourcePath == source:
      return module.artifactPath

proc declarationNames(refresh: CompilerRefreshResult, source: string): seq[string] =
  for module in refresh.snapshot.modules:
    if module.sourcePath == source:
      for symbol in module.symbols:
        result.add(symbol.name)
  result.sort()

proc locatedDeclarations(refresh: CompilerRefreshResult, source: string): seq[string] =
  let document =
    initDocumentSnapshot(documentUriFromPath(source), readFile(source), 0, peUtf16)
  for module in refresh.snapshot.modules:
    if module.sourcePath == source:
      for symbol in module.symbols:
        var start, finish: int
        if symbol.location.valid and symbol.location.path == source and
            document.tryTokenSpanAt(
              symbol.location.line, symbol.location.column, symbol.name, start, finish
            ):
          result.add(
            symbol.name & ":" & symbol.kind & ":" & $symbol.location.line & ":" &
              $symbol.location.column
          )
  result.sort()

proc compilerRuns(refresh: CompilerRefreshResult): Table[string, Time] =
  # The compiler always writes edge cookies when a module is checked, including
  # when the semantic BIF itself is byte-identical. This observes actual work.
  for artifact in refresh.artifactPaths:
    let edge = artifact[0 ..< artifact.len - ".s.bif".len] & ".edges.bif"
    result[artifact] = getLastModificationTime(edge)

proc frontendCache(refresh: CompilerRefreshResult): string =
  for argument in refresh.commandLines[0].splitWhitespace():
    if argument.startsWith("--nimcache:"):
      return argument["--nimcache:".len .. ^1]

suite "incremental compiler frontend":
  test "counts compiler module rules from a frontend graph":
    let root = createTempDir("nimdex-graph-count-", "")
    defer:
      removeDir(root)
    createDir(root / "configs" / "test" / "sem")
    let graph = root / "configs" / "test" / "sem" / "main.frontend.build.nif"
    check incrementalExpectedModules(root) == 0
    writeFile(graph, "(.nif27)\n(stmts (do nim_m) (do nifler) (do nim_m))\n")
    check incrementalExpectedModules(root) == 2
    let signature = "active configuration"
    let active = root / "configs" / $secureHash(signature) / "sem"
    createDir(active)
    writeFile(root / "ic_build_args.txt", signature)
    writeFile(active / "main.frontend.build.nif", "(.nif27)\n(stmts (do nim_m))\n")
    check incrementalExpectedModules(root) == 1

  test "defaults saved-source analysis to track":
    let root = normalizeDocumentPath(createTempDir("nimdex-default-track-", ""))
    defer:
      removeDir(root)
    let head = root / "main.nim"
    writeFile(head, "const defaultIcValue* = 1\n")
    let workspace = initWorkspace(
      documentUriFromPath(root), entryPoints = @[head], cacheRoot = root / ".nimdex"
    )
    check workspace.compilerFrontend == cfTrack
    let refreshed = runCompilerRefresh(
      CompilerRefreshRequest(workspace: workspace, capabilities: capabilities)
    )
    checkpoint refreshed.error & "\n" & refreshed.stderr
    require refreshed.ok
    require refreshed.commandLines.len == 1
    check " track " in refreshed.commandLines[0]
    check "--compileOnly:on" notin refreshed.commandLines[0]
    check "--processing:filenames" in refreshed.commandLines[0]
    check "[Processing]" in (refreshed.stdout & refreshed.stderr)
    let frontend = refreshed.frontendCache()
    require frontend.len > 0
    check incrementalExpectedModules(frontend) > 0
    let staleDir = frontend / "configs" / "obsolete" / "sem"
    createDir(staleDir)
    writeFile(staleDir / "stale.frontend.build.nif", "(.nif27)\n(stmts)\n")
    check incrementalArtifacts(frontend, head) == refreshed.artifactPaths
    check "defaultIcValue" in refreshed.declarationNames(head)

  test "checks frontend prerequisites separately and rejects unknown LSP modes":
    check capabilities.requireCompiler(cfTrack) == ""
    check capabilities.requireCompiler(cfIc) == ""
    var missing = capabilities
    missing.nifmakePath = ""
    check "nifmake" in missing.requireCompiler()
    check missing.requireCompiler(cfCompile) == ""
    check "nifmake" in missing.requireCompiler(cfTrack)
    check "nifmake" in missing.requireCompiler(cfIc)
    missing = capabilities
    missing.supportsTrack = false
    check "track" in missing.requireCompiler(cfTrack)
    let server = newNimdexLspServer()
    defer:
      server.close()
    let response = server.jsonRpcAdapter().handleJsonRpc(
        $(
          %*{
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
              "capabilities": {},
              "initializationOptions": {"compilerFrontend": "unknown"},
            },
          }
        )
      )
    check response.isSome()
    check parseJson(response.get())["error"]["code"].getInt() == -32602

  test "track rebuilds changed dirty buffers without altering saved analysis":
    let root = normalizeDocumentPath(createTempDir("nimdex-track-overlays-", ""))
    defer:
      removeDir(root)
    let head = root / "main.nim"
    let shared = root / "shared.nim"
    writeFile(head, "import shared\nconst savedHead* = shared.savedValue\n")
    writeFile(shared, "const savedValue* = 1\n")
    var request = requestFor(root, head)
    let saved = runCompilerRefresh(request)
    require saved.ok
    check "savedHead" in saved.declarationNames(head)
    request.overlays = @[
      initDocumentSnapshot(
        documentUriFromPath(head),
        "import shared\nconst dirtyHead* = shared.dirtyValue\n",
        1,
      ),
      initDocumentSnapshot(documentUriFromPath(shared), "const dirtyValue* = 2\n", 1),
    ]
    let first = runCompilerRefresh(request)
    checkpoint first.error & "\n" & first.stderr
    require first.ok
    check " track " in first.commandLines[0]
    check "dirtyHead" in first.declarationNames(head)
    check "dirtyValue" in first.declarationNames(shared)
    check "savedHead" notin first.declarationNames(head)
    check first.heads[0].cachePath.contains(DirSep & "overlays" & DirSep)
    request.previousHeads = first.heads
    request.overlays[1] = initDocumentSnapshot(
      documentUriFromPath(shared), "const dirtyValue* = 2\nconst nextValue* = 3\n", 2
    )
    let second = runCompilerRefresh(request)
    checkpoint second.error & "\n" & second.stderr
    require second.ok
    check "nextValue" in second.declarationNames(shared)
    check "dirtyHead" in second.declarationNames(head)
    request.previousHeads = second.heads
    request.overlays[1] =
      initDocumentSnapshot(documentUriFromPath(shared), "proc broken( = discard\n", 3)
    let failed = runCompilerRefresh(request)
    check not failed.ok
    request.overlays[1] = initDocumentSnapshot(
      documentUriFromPath(shared), "const dirtyValue* = 4\nconst recovered* = 5\n", 4
    )
    let recovered = runCompilerRefresh(request)
    checkpoint recovered.error & "\n" & recovered.stderr
    require recovered.ok
    check "recovered" in recovered.declarationNames(shared)
    request.overlays.setLen(0)
    request.previousHeads.setLen(0)
    let restored = runCompilerRefresh(request)
    require restored.ok
    check restored.restoredHeads == 1
    check "savedHead" in restored.declarationNames(head)
    check "savedValue" in restored.declarationNames(shared)
    check "dirtyValue" notin restored.declarationNames(shared)

  test "ic reuses the incremental graph and skips native compilation":
    let root = normalizeDocumentPath(createTempDir("nimdex-ic-", ""))
    defer:
      removeDir(root)
    let head = root / "main.nim"
    let shared = root / "support.nim"
    for name in ["main.nim", "support.nim"]:
      copyFile(RepositoryRoot / "tests/fixtures/binny_phase0" / name, root / name)
    let sharedContents = readFile(shared)
    let tracked = runCompilerRefresh(requestFor(root, head))
    require tracked.ok
    var request = requestFor(root, head, cfIc)
    let cold = runCompilerRefresh(request)
    checkpoint cold.error & "\n" & cold.stderr
    require cold.ok
    check cold.locatedDeclarations(head) == tracked.locatedDeclarations(head)
    check cold.locatedDeclarations(shared) == tracked.locatedDeclarations(shared)
    check cold.snapshot.graph.headsFor(shared) == @[head]
    check cold.cachePath != tracked.cachePath
    var cFiles = 0
    for path in walkDirRec(cold.frontendCache()):
      if path.endsWith(".c"):
        inc cFiles
      check path.splitFile.ext notin [".o", ".obj", ".exe", ".dylib"]
    check cFiles > 0

    let restored = runCompilerRefresh(request)
    require restored.ok
    check restored.restoredHeads == 1
    check restored.compiledHeads == 0

    request.previousHeads = restored.heads
    writeFile(shared, sharedContents & "\nconst icAdded* = 1\n")
    let changed = runCompilerRefresh(request)
    checkpoint changed.error & "\n" & changed.stderr
    require changed.ok
    check changed.compiledHeads == 1
    check "icAdded" in changed.declarationNames(shared)
    check changed.snapshot.graph.headsFor(shared) == @[head]

    writeFile(shared, "proc broken( = discard\n")
    request.previousHeads = changed.heads
    let failed = runCompilerRefresh(request)
    check not failed.ok
    check failed.diagnostics.len > 0
    writeFile(shared, sharedContents & "\nproc recovered*(): int = 1\n")
    let recovered = runCompilerRefresh(request)
    checkpoint recovered.error & "\n" & recovered.stderr
    require recovered.ok
    check "recovered" in recovered.declarationNames(shared)

  test "matches ordinary declarations and locations without backend outputs":
    let root = normalizeDocumentPath(createTempDir("nimdex-track-parity-", ""))
    defer:
      removeDir(root)
    let head = root / "main.nim"
    for name in ["main.nim", "support.nim"]:
      copyFile(RepositoryRoot / "tests/fixtures/binny_phase0" / name, root / name)
    let classic = runCompilerRefresh(requestFor(root, head, cfCompile))
    let tracked = runCompilerRefresh(requestFor(root, head))
    require classic.ok
    checkpoint tracked.error & "\n" & tracked.stderr
    require tracked.ok
    check tracked.cachePath != classic.cachePath
    # Classic codegen may attach generated stdlib helpers to the main BIF.
    # Compare the declarations actually located in each fixture source.
    for source in [head, root / "support.nim"]:
      check tracked.locatedDeclarations(source) == classic.locatedDeclarations(source)
    check "exportedRoutine" in tracked.declarationNames(head)
    check tracked.snapshot.graph.headsFor(root / "support.nim") == @[head]
    check fileExists(headManifestPath(tracked.heads[0].cachePath))
    check tracked.heads[0].cachePath != tracked.artifactPaths[0].parentDir
    for path in walkDirRec(tracked.frontendCache()):
      check path.splitFile.ext notin
        [".c", ".cpp", ".o", ".obj", ".exe", ".so", ".dylib"]

  test "retains per-module work, follows live imports, and recovers from errors":
    let root = normalizeDocumentPath(createTempDir("nimdex-track-edits-", ""))
    defer:
      removeDir(root)
    let head = root / "main.nim"
    let shared = root / "shared.nim"
    let removed = root / "removed.nim"
    writeFile(shared, "proc value*(): int = 1\n")
    writeFile(removed, "const removedValue* = 1\n")
    writeFile(head, "import shared, removed\nproc answer*(): int = value()\n")
    var request = requestFor(root, head)
    let cold = runCompilerRefresh(request)
    checkpoint cold.error & "\n" & cold.stderr
    require cold.ok
    let firstRuns = cold.compilerRuns()
    let headArtifact = cold.artifactFor(head)
    let sharedArtifact = cold.artifactFor(shared)
    let removedArtifact = cold.artifactFor(removed)
    let restored = runCompilerRefresh(request)
    check restored.ok
    check restored.restoredHeads == 1
    check restored.compiledHeads == 0
    check restored.loadedArtifacts > 0

    # Exercise the compiler's no-op path independently of Nimdex's whole-head cache.
    forgetHead(cold.heads[0].cachePath)
    let unchanged = runCompilerRefresh(request)
    require unchanged.ok
    check unchanged.compiledHeads == 1
    check unchanged.compilerRuns() == firstRuns

    writeFile(shared, "proc value*(): int = 2\n")
    request.previousHeads = unchanged.heads
    let bodyEdit = runCompilerRefresh(request)
    checkpoint bodyEdit.error & "\n" & bodyEdit.stderr
    require bodyEdit.ok
    let bodyRuns = bodyEdit.compilerRuns()
    check bodyRuns[headArtifact] == firstRuns[headArtifact]
    check bodyRuns[sharedArtifact] > firstRuns[sharedArtifact]
    check bodyEdit.reusedArtifacts > 0

    writeFile(shared, "proc value*(): int = 2\nconst added* = 3\n")
    request.previousHeads = bodyEdit.heads
    let interfaceEdit = runCompilerRefresh(request)
    require interfaceEdit.ok
    check interfaceEdit.compilerRuns()[headArtifact] > bodyRuns[headArtifact]
    check "added" in interfaceEdit.declarationNames(shared)

    writeFile(head, "import shared\nproc answer*(): int = value()\n")
    request.previousHeads = interfaceEdit.heads
    let pruned = runCompilerRefresh(request)
    checkpoint pruned.error & "\n" & pruned.stderr
    require pruned.ok
    check fileExists(removedArtifact)
    check removedArtifact notin pruned.artifactPaths
    check not pruned.snapshot.containsModule(removed)
    check pruned.snapshot.graph.headsFor(removed).len == 0

    writeFile(shared, "proc broken( = discard\n")
    request.previousHeads = pruned.heads
    let failed = runCompilerRefresh(request)
    check not failed.ok
    check failed.diagnostics.len > 0
    check not fileExists(headManifestPath(cold.heads[0].cachePath))
    writeFile(shared, "proc value*(): int = 4\n")
    let recovered = runCompilerRefresh(request)
    checkpoint recovered.error & "\n" & recovered.stderr
    require recovered.ok
    check "value" in recovered.declarationNames(shared)

    let deps = headArtifact[0 ..< headArtifact.len - ".s.bif".len] & ".s.deps.bif"
    writeFile(deps, "broken")
    expect ValueError:
      discard incrementalArtifacts(headArtifact.parentDir, head)

  test "rechecks compile-time body dependencies and preserves include and head context":
    let root = normalizeDocumentPath(createTempDir("nimdex-track-static-", ""))
    defer:
      removeDir(root)
    let head = root / "main.nim"
    let shared = root / "shared.nim"
    writeFile(root / "piece.nim", "const included* = 7\n")
    writeFile(shared, "proc value*(): int = 1\n")
    writeFile(root / "extra.nim", "const extraValue* = 9\n")
    writeFile(root / "implicit.nim", "const implicitValue* = 10\n")
    writeFile(root / "config.nims", "switch(\"import\", \"implicit\")\n")
    writeFile(
      head,
      """
import std/macros
import shared
include piece
macro loadExtra(): untyped = parseStmt("import extra")
loadExtra()
proc identity[T](value: T): T = value
const checkedValue* = identity(value())
when checkedValue == 1:
  const before* = true
else:
  const after* = true
when isMainModule:
  const mainContext* = true
when defined(testContext):
  const testContextValue* = true
""",
    )
    var request = requestFor(root, head)
    let cold = runCompilerRefresh(request)
    checkpoint cold.error & "\n" & cold.stderr
    require cold.ok
    for name in ["included", "checkedValue", "before", "mainContext"]:
      check name in cold.declarationNames(head)
    check cold.snapshot.graph.headsFor(root / "piece.nim") == @[head]
    check cold.snapshot.containsModule(root / "extra.nim")
    check cold.snapshot.containsModule(root / "implicit.nim")
    let firstRuns = cold.compilerRuns()
    writeFile(shared, "proc value*(): int = 2\n")
    request.previousHeads = cold.heads
    let changed = runCompilerRefresh(request)
    checkpoint changed.error & "\n" & changed.stderr
    require changed.ok
    check changed.compilerRuns()[cold.artifactFor(head)] >
      firstRuns[cold.artifactFor(head)]
    check "after" in changed.declarationNames(head)
    check "before" notin changed.declarationNames(head)

    writeFile(root / "config.nims", "switch(\"define\", \"testContext\")\n")
    request.previousHeads = changed.heads
    let configured = runCompilerRefresh(request)
    checkpoint configured.error & "\n" & configured.stderr
    require configured.ok
    check "testContextValue" in configured.declarationNames(head)
    check not configured.snapshot.containsModule(root / "implicit.nim")
    writeFile(head.changeFileExt("nims"), "switch(\"undef\", \"testContext\")\n")
    request.previousHeads = configured.heads
    let newConfig = runCompilerRefresh(request)
    checkpoint newConfig.error & "\n" & newConfig.stderr
    require newConfig.ok
    check "testContextValue" notin newConfig.declarationNames(head)

  test "entry points in different directories share frontend work":
    let root = normalizeDocumentPath(createTempDir("nimdex-shared-heads-", ""))
    defer:
      removeDir(root)
    createDir(root / "src")
    createDir(root / "tests")
    let first = root / "src/app.nim"
    let second = root / "tests/tapp.nim"
    let shared = root / "src/shared.nim"
    writeFile(shared, "const common* = 1\n")
    writeFile(first, "import shared\nconst appValue* = common\n")
    writeFile(second, "import shared\nconst testValue* = common\n")
    let request = CompilerRefreshRequest(
      workspace: initWorkspace(
        documentUriFromPath(root),
        entryPoints = @[first, second],
        importPaths = @[root / "src"],
        cacheRoot = root / "cache",
        compilerFrontend = cfTrack,
      ),
      capabilities: capabilities,
    )
    var firstArtifact: string
    var firstModified: Time
    let refreshed = runCompilerRefresh(
      request,
      onHead = proc(progress: CompilerHeadProgress) =
        if progress.ok and progress.headPath == first:
          for module in progress.analysis.snapshot[].modules:
            if module.sourcePath == shared:
              firstArtifact = module.artifactPath
              firstModified = getLastModificationTime(firstArtifact)
      ,
    )
    checkpoint refreshed.error & "\n" & refreshed.stderr
    require refreshed.ok
    require refreshed.heads.len == 2
    require firstArtifact.len > 0
    let secondArtifact = refreshed.heads[1].snapshot[].findModule(shared).artifactPath
    check secondArtifact == firstArtifact
    check getLastModificationTime(secondArtifact) == firstModified
    check refreshed.heads[0].snapshot[].findSymbols("appValue").len == 1
    check refreshed.heads[1].snapshot[].findSymbols("testValue").len == 1

  test "test entry points share an IC cache and preserve their main modules":
    let root = normalizeDocumentPath(createTempDir("nimdex-shared-tests-", ""))
    defer:
      removeDir(root)
    createDir(root / "tests")
    let first = root / "tests" / "ta.nim"
    let second = root / "tests" / "tb.nim"
    let shared = root / "tests" / "shared.nim"
    writeFile(shared, "const common* = 1\n")
    writeFile(first, "import shared\nwhen isMainModule:\n  const onlyA* = common\n")
    writeFile(
      second, "import shared, ta\nwhen isMainModule:\n  const onlyB* = common\n"
    )
    var request = CompilerRefreshRequest(
      workspace: initWorkspace(
        documentUriFromPath(root),
        entryPoints = @[first, second],
        importPaths = @[root / "tests"],
        cacheRoot = root / "cache",
        compilerFrontend = cfIc,
      ),
      capabilities: capabilities,
    )
    let cold = runCompilerRefresh(request)
    checkpoint cold.error & "\n" & cold.stderr
    require cold.ok
    require cold.heads.len == 2
    require cold.commandLines.len == 2
    var caches: seq[string]
    for command in cold.commandLines:
      for argument in command.splitWhitespace():
        if argument.startsWith("--nimcache:"):
          caches.add(argument)
    require caches.len == 2
    check caches[0] == caches[1]
    check cold.heads[0].cachePath != cold.heads[1].cachePath
    check cold.heads[0].snapshot[].findSymbols("onlyA").len == 1
    check cold.heads[0].snapshot[].findSymbols("onlyB").len == 0
    check cold.heads[1].snapshot[].findSymbols("onlyB").len == 1
    check cold.heads[1].snapshot[].findSymbols("onlyA").len == 0
    request.previousHeads = cold.heads
    writeFile(shared, "const common* = 2\n")
    let updated = runCompilerRefresh(request)
    checkpoint updated.error & "\n" & updated.stderr
    require updated.ok
    check updated.compiledHeads == 2
    check updated.heads[0].snapshot[].findSymbols("onlyA").len == 1
    check updated.heads[1].snapshot[].findSymbols("onlyB").len == 1

  test "keeps actual-head and test configuration variants isolated":
    let root = normalizeDocumentPath(createTempDir("nimdex-track-heads-", ""))
    defer:
      removeDir(root)
    createDir(root / "src")
    createDir(root / "tests")
    writeFile(root / "sample.nimble", "srcDir = \"src\"\n")
    let packageHead = root / "src/sample.nim"
    let testHead = root / "tests/tsample.nim"
    let shared = root / "src/shared.nim"
    writeFile(shared, "const sharedValue* = 1\n")
    writeFile(
      packageHead,
      """
import shared
when isMainModule:
  const mainOnly* = true
when defined(testContext):
  const testOnly* = true
else:
  const packageOnly* = true
""",
    )
    writeFile(root / "tests/config.nims", "switch(\"define\", \"testContext\")\n")
    writeFile(
      testHead, "import sample, shared\nwhen isMainModule:\n  const testMain* = true\n"
    )
    let refreshed = runCompilerRefresh(
      CompilerRefreshRequest(
        workspace: initWorkspace(documentUriFromPath(root), compilerFrontend = cfTrack),
        capabilities: capabilities,
      )
    )
    checkpoint refreshed.error & "\n" & refreshed.stderr
    require refreshed.ok
    check refreshed.compiledHeads == 2
    require refreshed.heads.len == 2
    let firstShared = refreshed.heads[0].snapshot[].findModule(shared).artifactPath
    let secondShared = refreshed.heads[1].snapshot[].findModule(shared).artifactPath
    check firstShared != secondShared
    check firstShared.contains(DirSep & "frontends" & DirSep)
    check secondShared.contains(DirSep & "frontends" & DirSep)
    check refreshed.snapshot.graph.headsFor(packageHead) == @[packageHead, testHead]
    for analysis in refreshed.heads:
      let names = analysis.snapshot[].findSymbols("mainOnly")
      if analysis.headPath == packageHead:
        check names.len == 1
        check analysis.snapshot[].findSymbols("packageOnly").len == 1
        check analysis.snapshot[].findSymbols("testOnly").len == 0
      else:
        check names.len == 0
        check analysis.snapshot[].findSymbols("testOnly").len == 1
        check analysis.snapshot[].findSymbols("testMain").len == 1

  test "serves symbols after a comment edit with byte-identical compiler artifacts":
    let root = normalizeDocumentPath(createTempDir("nimdex-track-lsp-", ""))
    defer:
      removeDir(root)
    let head = root / "main.nim"
    writeFile(head, "proc visible*(): int = 1\n")
    writeFile(root / "nim.cfg", "--nimcache:\"compiler-cache\"\n")
    let server = newNimdexLspServer(compilerPath = capabilities.compilerPath)
    defer:
      server.close()
    let initialized = server.jsonRpcAdapter().handleJsonRpc(
        $(
          %*{
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
              "rootUri": documentUriFromPath(root),
              "capabilities": {},
              "initializationOptions": {"compilerFrontend": "track"},
            },
          }
        )
      )
    require initialized.isSome()
    require parseJson(initialized.get()).hasKey("result")
    discard server.jsonRpcAdapter().handleJsonRpc(
        $(%*{"jsonrpc": "2.0", "method": "initialized", "params": {}})
      )
    let query = $(
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/documentSymbol",
        "params": {"textDocument": {"uri": documentUriFromPath(head)}},
      }
    )
    let before = parseJson(server.jsonRpcAdapter().handleJsonRpc(query).get())
    require before.hasKey("result")
    require before["result"].len > 0
    var artifacts: Table[string, Time]
    for path in walkDirRec(root / ".nimdex"):
      if path.endsWith(".s.bif"):
        artifacts[path] = getLastModificationTime(path)
    require artifacts.len > 0
    writeFile(head, "proc visible*(): int = 1\n# comment\n")
    discard server.jsonRpcAdapter().handleJsonRpc(
        $(
          %*{
            "jsonrpc": "2.0",
            "method": "textDocument/didSave",
            "params": {"textDocument": {"uri": documentUriFromPath(head)}},
          }
        )
      )
    let after = parseJson(server.jsonRpcAdapter().handleJsonRpc(query).get())
    check after["result"] == before["result"]
    for path, modified in artifacts:
      check getLastModificationTime(path) == modified
