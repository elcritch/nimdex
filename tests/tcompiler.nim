import std/[assertions, json, options, os, strutils, unittest]

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

suite "Nimdex compiler refresh":
  test "probes the required BIF compiler capability":
    let capabilities = probeCompiler(projectCompiler())
    doAssert capabilities.available
    doAssert capabilities.supportsGenBif
    doAssert capabilities.compilerPath == normalizeDocumentPath(projectCompiler())
    doAssert capabilities.fingerprint != 0

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
