import std/[assertions, json, options, os, strutils, tables, unittest]

import nimdex/compiler
import nimdex/documents
import nimdex/lsp
import nimdex/semantic
import nimdex/workspace
import sigils/rpcs/jsonrpc

const
  FixtureRoot = currentSourcePath.parentDir / "fixtures/binny_phase0"
  FixtureMain = FixtureRoot / "main.nim"

proc projectCompiler(): string =
  currentSourcePath.parentDir.parentDir / "deps/nim-devel/bin/nim"

proc refreshFor(
    root, entryPoint, cacheRoot: string, source: CompilerCapabilities
): CompilerRefreshResult =
  let workspace = initWorkspace(
    documentUriFromPath(root),
    entryPoints = @[entryPoint],
    importPaths = @[root],
    compilerPath = source.compilerPath,
    cacheRoot = cacheRoot,
  )
  runCompilerRefresh(CompilerRefreshRequest(workspace: workspace, capabilities: source))

proc responseFor(server: LspServer, message: JsonNode): JsonNode =
  let response = server.jsonRpcAdapter().handleJsonRpc($message)
  doAssert response.isSome()
  parseJson(response.get())

proc notify(server: LspServer, name: string, params: JsonNode) =
  discard server.jsonRpcAdapter().handleJsonRpc(
      $(%*{"jsonrpc": "2.0", "method": name, "params": params})
    )

proc debugState(server: LspServer): JsonNode =
  responseFor(
    server, %*{"jsonrpc": "2.0", "id": 90, "method": "nimdex/debug", "params": {}}
  )["result"]

suite "Nimdex compiler refresh":
  test "refreshes on save and file events and exposes project graph and reuse":
    let root =
      normalizeDocumentPath(getTempDir() / ("nimdex-save-" & $getCurrentProcessId()))
    createDir(root / "src")
    createDir(root / "tests")
    defer:
      removeDir(root)
    writeFile(root / "sample.nimble", "srcDir = \"src\"\n")
    let source = root / "src/sample.nim"
    let uri = documentUriFromPath(source)
    writeFile(source, "proc before*(): int = 1\n")
    writeFile(root / "tests/tcheck.nim", "import sample\ndiscard before()\n")
    let server = newNimdexLspServer(compilerPath = projectCompiler())
    defer:
      server.close()
    let initialized = responseFor(
      server,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"rootUri": documentUriFromPath(root), "capabilities": {}},
      },
    )
    check initialized["result"]["capabilities"]["textDocumentSync"]["save"].getBool()
    server.notify("initialized", %*{})
    let cold = server.debugState()
    check cold["refresh"]["compiledHeads"].getInt() == 2
    check cold["moduleGraph"]["actualHeads"].len == 2
    server.notify(
      "textDocument/didOpen",
      %*{"textDocument": {"uri": uri, "version": 1, "text": readFile(source)}},
    )
    let edited = "proc before*(): int = 2\nproc after*(): int = 3\n"
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": edited}]
      },
    )
    let unsaved = server.debugState()
    check unsaved["refresh"]["compiledHeads"].getInt() == 2
    check unsaved["semantic"]["sourceFingerprint"] !=
      cold["semantic"]["sourceFingerprint"]
    writeFile(source, edited)
    server.notify("textDocument/didSave", %*{"textDocument": {"uri": uri}})
    let saved = server.debugState()
    check saved["refresh"]["compiledHeads"].getInt() == 2
    check saved["semantic"]["sourceFingerprint"] != cold["semantic"][
      "sourceFingerprint"
    ]
    let symbols = responseFor(
      server,
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/documentSymbol",
        "params": {"textDocument": {"uri": uri}},
      },
    )
    var afterCount = 0
    for symbol in symbols["result"]:
      if symbol["name"].getStr() == "after":
        inc afterCount
    check afterCount == 1
    server.notify("textDocument/didSave", %*{"textDocument": {"uri": uri}})
    let warm = server.debugState()
    check warm["refresh"]["compiledHeads"].getInt() == 0
    check warm["refresh"]["reusedHeads"].getInt() == 2

    let added = root / "tests/tnew.nim"
    writeFile(added, "import sample\ndiscard after()\n")
    server.notify(
      "workspace/didChangeWatchedFiles",
      %*{"changes": [{"uri": documentUriFromPath(added), "type": 1}]},
    )
    check server.debugState()["moduleGraph"]["actualHeads"].len == 3
    removeFile(added)
    server.notify(
      "workspace/didChangeWatchedFiles",
      %*{"changes": [{"uri": documentUriFromPath(added), "type": 3}]},
    )
    let removed = server.debugState()
    check removed["moduleGraph"]["actualHeads"].len == 2

    server.notify("textDocument/didClose", %*{"textDocument": {"uri": uri}})
    writeFile(source, "proc broken( = discard\n")
    server.notify("textDocument/didSave", %*{"textDocument": {"uri": uri}})
    let failed = server.debugState()
    check not failed["semantic"]["ready"].getBool()
    check failed["refresh"]["error"].getStr().len > 0
    check failed["semantic"]["moduleCount"].getInt() == 0
    check failed["refresh"]["failedHeads"].len == 2

  test "maps actual heads and reuses shared modules and unchanged analyses":
    let root =
      normalizeDocumentPath(getTempDir() / ("nimdex-heads-" & $getCurrentProcessId()))
    createDir(root / "lib")
    createDir(root / "tests")
    defer:
      removeDir(root)
    writeFile(root / "sample.nimble", "srcDir = \"lib\"\n")
    writeFile(
      root / "lib/sample.nim",
      "import shared\nexport shared\nwhen isMainModule:\n  const mainOnly* = 1\n",
    )
    writeFile(
      root / "lib/shared.nim",
      "include piece\nwhen defined(testContext):\n  import extra\n  export extra\nproc sharedValue*(): int = includedValue\n",
    )
    writeFile(root / "lib/piece.nim", "const includedValue* = 7\n")
    writeFile(root / "lib/extra.nim", "const testOnly* = 9\n")
    writeFile(root / "lib/onlya.nim", "const onlyA* = 1\n")
    writeFile(root / "tests/config.nims", "switch(\"define\", \"testContext\")\n")
    writeFile(
      root / "tests/ta.nim", "import sample, onlya\ndoAssert sharedValue() == 7\n"
    )
    writeFile(root / "tests/tb.nim", "import sample\ndoAssert sharedValue() == 7\n")
    writeFile(root / "tests/tisolated.nim", "const isolated* = 1\n")
    let workspace =
      initWorkspace(documentUriFromPath(root), cacheRoot = root / ".nimdex/cache")
    var request = CompilerRefreshRequest(
      workspace: workspace, capabilities: probeCompiler(projectCompiler())
    )
    let cold = runCompilerRefresh(request)
    check cold.ok
    check cold.compiledHeads == 4
    check cold.reusedArtifacts > 0
    check cold.snapshot.graph.heads == workspace.discoverCompilerEntryPoints()
    check cold.snapshot.graph.headsFor(root / "lib/shared.nim") ==
      @[root / "lib/sample.nim", root / "tests/ta.nim", root / "tests/tb.nim"]
    check cold.snapshot.graph.headsFor(root / "lib/piece.nim") ==
      cold.snapshot.graph.headsFor(root / "lib/shared.nim")
    check cold.snapshot.graph.headsFor(root / "lib/extra.nim") ==
      @[root / "tests/ta.nim", root / "tests/tb.nim"]
    check cold.snapshot.graph.importers[root / "lib/shared.nim"] ==
      @[root / "lib/sample.nim"]
    var mainVariants = 0
    for module in cold.snapshot.modules:
      if module.sourcePath == root / "lib/sample.nim":
        inc mainVariants
    check mainVariants >= 2
    let restarted = runCompilerRefresh(request)
    check restarted.ok
    check restarted.compiledHeads == 0
    check restarted.restoredHeads == 4
    check restarted.loadedArtifacts == 0
    check restarted.snapshot.moduleCount() == cold.snapshot.moduleCount()
    check restarted.snapshot.graph.headsFor(root / "lib/piece.nim") ==
      cold.snapshot.graph.headsFor(root / "lib/piece.nim")
    check restarted.snapshot.findSymbols("sharedValue").len ==
      cold.snapshot.findSymbols("sharedValue").len
    request.previousHeads = cold.heads
    let warm = runCompilerRefresh(request)
    check warm.ok
    check warm.compiledHeads == 0
    check warm.reusedHeads == 4
    check warm.loadedArtifacts == 0
    check warm.commandLines.len == 0
    check warm.diagnostics == cold.diagnostics
    check warm.snapshot.moduleCount() == cold.snapshot.moduleCount()

    writeFile(root / "lib/onlya.nim", "const onlyA* = 2\n")
    request.previousHeads = warm.heads
    let oneChanged = runCompilerRefresh(request)
    check oneChanged.ok
    check oneChanged.compiledHeads == 1
    check oneChanged.reusedHeads == 3

    writeFile(root / "lib/piece.nim", "const includedValue* = 8\n")
    request.previousHeads = oneChanged.heads
    let sharedChanged = runCompilerRefresh(request)
    check sharedChanged.ok
    check sharedChanged.compiledHeads == 3
    check sharedChanged.reusedHeads == 1
    request.previousHeads = sharedChanged.heads
    writeFile(root / "tests/config.nims", "switch(\"define\", \"anotherContext\")\n")
    let configChanged = runCompilerRefresh(request)
    check configChanged.ok
    check configChanged.compiledHeads == 3
    check configChanged.reusedHeads == 1
    check configChanged.snapshot.graph.headsFor(root / "lib/extra.nim").len == 0
    check not configChanged.snapshot.containsModule(root / "lib/extra.nim")

    request.previousHeads = configChanged.heads
    writeFile(root / "lib/onlya.nim", "proc broken( = discard\n")
    let failed = runCompilerRefresh(request)
    check not failed.ok
    check failed.snapshot.moduleCount() > 0
    check failed.failedHeads == @[root / "tests/ta.nim"]
    check failed.heads.len == 3
    check not failed.snapshot.containsModule(root / "tests/ta.nim")
    check configChanged.snapshot.moduleCount() > 0
    writeFile(root / "lib/onlya.nim", "const onlyA* = 3\n")
    let recovered = runCompilerRefresh(request)
    check recovered.ok
    check recovered.compiledHeads == 1
    check recovered.reusedHeads == 3

  test "prioritizes pending heads and continues after an independent failure":
    let root = normalizeDocumentPath(
      getTempDir() / ("nimdex-priority-" & $getCurrentProcessId())
    )
    createDir(root)
    defer:
      removeDir(root)
    let a = root / "a.nim"
    let b = root / "b.nim"
    let c = root / "c.nim"
    writeFile(a, "proc broken( = discard\n")
    writeFile(b, "const second* = 2\n")
    writeFile(c, "const first* = 1\n")
    let cancellation = newCompilerCancellation()
    defer:
      cancellation.releaseCompilerCancellation()
    let request = CompilerRefreshRequest(
      workspace: initWorkspace(documentUriFromPath(root), entryPoints = @[a, b, c]),
      capabilities: probeCompiler(projectCompiler()),
      cancellation: cancellation,
      priorityHead: c,
    )
    var order: seq[string]
    let refreshed = runCompilerRefresh(
      request,
      proc(progress: CompilerHeadProgress) =
        order.add(progress.headPath)
        if order.len == 1:
          check progress.ok
          check progress.analysis.snapshot[].findSymbols("first").len > 0
          cancellation.prioritizeCompilerHead(1)
      ,
    )
    check order == @[c, b, a]
    check not refreshed.ok
    check refreshed.failedHeads == @[a]
    check refreshed.heads.len == 2
    check refreshed.snapshot.findSymbols("second").len > 0

  test "probes the required BIF compiler capability":
    let capabilities = probeCompiler(projectCompiler())
    doAssert capabilities.available
    doAssert capabilities.supportsGenBif
    doAssert capabilities.compilerPath == normalizeDocumentPath(projectCompiler())
    doAssert capabilities.fingerprint != 0

  test "uses the selected head context and keeps healthy heads after failure":
    let root =
      normalizeDocumentPath(getTempDir() / ("nimdex-context-" & $getCurrentProcessId()))
    createDir(root / "src")
    createDir(root / "tests")
    defer:
      removeDir(root)
    writeFile(root / "sample.nimble", "srcDir = \"src\"\n")
    writeFile(root / "src/sample.nim", "import shared\n")
    let shared = root / "src/shared.nim"
    writeFile(
      shared,
      "when defined(testContext):\n  const selected* = 1\nelse:\n  const normal* = 2\n",
    )
    writeFile(root / "tests/config.nims", "switch(\"define\", \"testContext\")\n")
    let testHead = root / "tests/tcheck.nim"
    writeFile(testHead, "import sample\n")
    let server = newNimdexLspServer(compilerPath = projectCompiler())
    defer:
      server.close()
    discard responseFor(
      server,
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "rootUri": documentUriFromPath(root),
          "capabilities": {},
          "initializationOptions":
            {"preferredHeads": {"src/shared.nim": "tests/tcheck.nim"}},
        },
      },
    )
    server.notify("initialized", %*{})
    let query =
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/documentSymbol",
        "params": {"textDocument": {"uri": documentUriFromPath(shared)}},
      }
    let symbols = responseFor(server, query)
    var names: seq[string]
    for symbol in symbols["result"]:
      names.add(symbol["name"].getStr())
    check "selected" in names
    check "normal" notin names
    writeFile(testHead, "proc broken( = discard\n")
    server.notify(
      "textDocument/didSave", %*{"textDocument": {"uri": documentUriFromPath(testHead)}}
    )
    let status = server.debugState()
    check status["semantic"]["ready"].getBool()
    check status["refresh"]["failedHeads"].len == 1
    check responseFor(server, query)["error"]["code"].getInt() == LspAnalysisUnavailable
    let healthy = responseFor(
      server,
      %*{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "textDocument/documentSymbol",
        "params":
          {"textDocument": {"uri": documentUriFromPath(root / "src/sample.nim")}},
      },
    )
    check healthy.hasKey("result")

  test "rejects an unavailable configured compiler during initialization":
    let server = newNimdexLspServer()
    defer:
      server.close()
    var initializeParams = newJObject()
    initializeParams["rootUri"] = %documentUriFromPath(FixtureRoot)
    initializeParams["capabilities"] = newJObject()
    var optionsNode = newJObject()
    optionsNode["compilerPath"] = %"/no/such/nimdex-compiler"
    initializeParams["initializationOptions"] = optionsNode
    var initialize = newJObject()
    initialize["jsonrpc"] = %"2.0"
    initialize["id"] = %1
    initialize["method"] = %"initialize"
    initialize["params"] = initializeParams
    let response = responseFor(server, initialize)
    doAssert response["error"]["code"].getInt() == LspCompilerUnavailable

  test "builds a stamped snapshot in a project cache":
    let cacheRoot = getTempDir() / ("nimdex-compiler-test-" & $getCurrentProcessId())
    let capabilities = probeCompiler(projectCompiler())
    let refresh = refreshFor(FixtureRoot, FixtureMain, cacheRoot, capabilities)
    doAssert refresh.ok, refresh.error
    doAssert refresh.exitCode == 0
    doAssert refresh.cachePath.startsWith(normalizeDocumentPath(cacheRoot))
    doAssert refresh.commandLines.len == 1
    doAssert "--genBif:on" in refresh.commandLines[0]
    doAssert refresh.artifactPaths.len > 0
    doAssert refresh.snapshot.moduleCount() > 0
    doAssert refresh.snapshot.compilerFingerprint == capabilities.fingerprint
    doAssert refresh.snapshot.sourceFingerprint != 0
    doAssert refresh.stamp.sourceFingerprint == refresh.snapshot.sourceFingerprint

  test "returns compiler diagnostics without a partial snapshot":
    let root = getTempDir() / ("nimdex-compiler-error-" & $getCurrentProcessId())
    if not dirExists(root):
      createDir(root)
    let sourcePath = root / "broken.nim"
    writeFile(sourcePath, "proc broken( = discard\n")
    let capabilities = probeCompiler(projectCompiler())
    let refresh = refreshFor(root, sourcePath, root / "cache", capabilities)
    doAssert not refresh.ok
    doAssert refresh.snapshot.moduleCount() == 0
    doAssert refresh.diagnostics.len > 0
    doAssert refresh.diagnostics[0].severity == cdsError
    doAssert refresh.diagnostics[0].sourceUri.len > 0

  test "retains semantic declarations without compiling or linking native code":
    let root = normalizeDocumentPath(
      getTempDir() / ("nimdex-semantic-check-" & $getCurrentProcessId())
    )
    createDir(root)
    defer:
      removeDir(root)
    let sourcePath = root / "main.nim"
    writeFile(
      sourcePath,
      """
import std/macros
macro declareValue(): untyped =
  parseStmt("const generatedValue* = 7")
declareValue()
proc identity[T](value: T): T = value
static:
  doAssert identity(generatedValue) == 7
const checkedValue* = identity(9)
when isMainModule:
  const mainContext* = true
""",
    )
    let refresh =
      refreshFor(root, sourcePath, root / "cache", probeCompiler(projectCompiler()))
    check refresh.ok
    var names: seq[string]
    for module in refresh.snapshot.modules:
      if module.sourcePath == sourcePath:
        for symbol in module.symbols:
          names.add(symbol.name)
    for expected in ["generatedValue", "checkedValue", "mainContext"]:
      check expected in names
    check refresh.artifactPaths.len > 0
    for path in walkDirRec(root / "cache"):
      check path.splitFile.ext notin [".o", ".obj", ".exe", ".dll", ".dylib", ".so"]
      check path.splitFile.name != "main" or path.splitFile.ext.len > 0

  test "installs the compiler snapshot before serving LSP queries":
    let cacheRoot = getTempDir() / ("nimdex-compiler-lsp-" & $getCurrentProcessId())
    let server = newNimdexLspServer(compilerPath = projectCompiler())
    defer:
      server.close()

    var initializeParams = newJObject()
    initializeParams["rootUri"] = %documentUriFromPath(FixtureRoot)
    initializeParams["capabilities"] = newJObject()
    var optionsNode = newJObject()
    optionsNode["entryPoints"] = newJArray()
    optionsNode["entryPoints"].add(%FixtureMain)
    optionsNode["cacheRoot"] = %cacheRoot
    initializeParams["initializationOptions"] = optionsNode

    var initialize = newJObject()
    initialize["jsonrpc"] = %"2.0"
    initialize["id"] = %1
    initialize["method"] = %"initialize"
    initialize["params"] = initializeParams
    let initializedResponse = responseFor(server, initialize)
    doAssert initializedResponse["result"]["capabilities"]["hoverProvider"].getBool()

    var initialized = newJObject()
    initialized["jsonrpc"] = %"2.0"
    initialized["method"] = %"initialized"
    initialized["params"] = newJObject()
    discard server.jsonRpcAdapter().handleJsonRpc($initialized)

    let sourceUri = documentUriFromPath(FixtureMain)
    var open = newJObject()
    open["jsonrpc"] = %"2.0"
    open["method"] = %"textDocument/didOpen"
    var openDocument = newJObject()
    openDocument["uri"] = %sourceUri
    openDocument["version"] = %1
    openDocument["text"] = %readFile(FixtureMain)
    var openParams = newJObject()
    openParams["textDocument"] = openDocument
    open["params"] = openParams
    discard server.jsonRpcAdapter().handleJsonRpc($open)

    var symbols = newJObject()
    symbols["jsonrpc"] = %"2.0"
    symbols["id"] = %2
    symbols["method"] = %"textDocument/documentSymbol"
    var symbolParams = newJObject()
    var symbolDocument = newJObject()
    symbolDocument["uri"] = %sourceUri
    symbolParams["textDocument"] = symbolDocument
    symbols["params"] = symbolParams
    let symbolResponse = responseFor(server, symbols)
    doAssert symbolResponse["result"].kind == JArray
    var foundExported = false
    for symbol in symbolResponse["result"]:
      if symbol["name"].getStr() == "exportedRoutine":
        foundExported = true
    doAssert foundExported
