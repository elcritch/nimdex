import std/[json, os, strutils, syncio, unittest]

import binny/bif
import nimdex/lsp
import nimdex/documents
import sigils/rpcs/json/jrFraming

proc framed(messages: openArray[string]): string =
  for message in messages:
    result.add(frameJsonRpcMessage(message))

proc readResponses(path: string): seq[JsonNode] =
  var parser = initJsonRpcFrameParser()
  parser.add(readFile(path))
  while true:
    let frame = parser.nextFrame()
    if frame.isNone():
      break
    result.add(parseJson(frame.get()))

proc runServer(
    messages: openArray[string], artifactRoots: seq[string] = @[]
): tuple[status: int, responses: seq[JsonNode]] =
  let suffix = $getCurrentProcessId()
  let
    inputPath = getTempDir() / ("nimdex-lsp-input-" & suffix & ".json")
    outputPath = getTempDir() / ("nimdex-lsp-output-" & suffix & ".json")
  writeFile(inputPath, framed(messages))

  var input = open(inputPath, fmRead)
  var output = open(outputPath, fmWrite)
  try:
    result.status =
      runNimdexLspStdio(input, output, workers = 1, artifactRoots = artifactRoots)
  finally:
    input.close()
    output.close()

  try:
    result.responses = readResponses(outputPath)
  finally:
    removeFile(inputPath)
    removeFile(outputPath)

proc rpcRequest(id: int, methodName: string, params: JsonNode): string =
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["id"] = %id
  message["method"] = %methodName
  message["params"] = params
  $message

proc rpcNotification(methodName: string, params: JsonNode): string =
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["method"] = %methodName
  message["params"] = params
  $message

proc writePhase2Bif(root, sourcePath: string) =
  var buffer = createTokenBuf()
  let
    moduleTag = buffer.tags.registerTag("module")
    sourceTag = buffer.tags.registerTag("modulesrc")
    declarationTag = buffer.tags.registerTag("sd")
    sourceFile = buffer.pool.filenames.getOrIncl(sourcePath)

  buffer.openTag(moduleTag)
  buffer.appendLineInfo(sourceFile, 1, 0)
  buffer.buildTree sourceTag:
    buffer.addStrLit(sourcePath)

  buffer.openTag(declarationTag)
  buffer.appendLineInfo(sourceFile, 2, 5)
  buffer.addSymDef("exported.0.phase2")
  buffer.closeTag()

  buffer.openTag(declarationTag)
  buffer.appendLineInfo(sourceFile, 3, 5)
  buffer.addSymDef("hidden.0.phase2")
  buffer.closeTag()
  buffer.closeTag()
  buffer.store(root / "main.s.bif")

suite "nimdex LSP server":
  test "runs lifecycle and full document synchronization":
    let run = runServer(
      [
        """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8","utf-16"]}}}}""",
        """{"jsonrpc":"2.0","method":"initialized","params":{}}""",
        """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/nimdex-phase1-sync.nim","languageId":"nim","version":1,"text":"alpha"}}}""",
        """{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///tmp/nimdex-phase1-sync.nim","version":2},"contentChanges":[{"text":"beta"}]}}""",
        """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///tmp/nimdex-phase1-sync.nim"}}}""",
        """{"jsonrpc":"2.0","id":4,"method":"shutdown"}""",
        """{"jsonrpc":"2.0","method":"exit"}""",
      ]
    )

    check run.status == LspExitSuccess
    check run.responses.len == 2
    check run.responses[0]["id"].getInt() == 1
    check run.responses[0]["result"]["capabilities"]["textDocumentSync"]["openClose"].getBool()
    check run.responses[0]["result"]["capabilities"]["textDocumentSync"]["change"].getInt() ==
      1
    check run.responses[0]["result"]["capabilities"]["positionEncoding"].getStr() ==
      "utf-8"
    check not run.responses[0]["result"]["capabilities"].hasKey("hoverProvider")
    check run.responses[1]["id"].getInt() == 4
    check run.responses[1]["result"].kind == JNull

  test "serves verified Binny-backed symbols and hover ranges":
    let root = getTempDir() / ("nimdex-lsp-phase2-" & $getCurrentProcessId())
    if dirExists(root):
      removeDir(root)
    createDir(root)
    defer:
      if dirExists(root):
        removeDir(root)

    let sourcePath = normalizeDocumentPath(root / "main.nim")
    let source = "# phase 2 fixture\nproc exported(): int = 1\nproc hidden(): int = 2\n"
    writeFile(sourcePath, source)
    writePhase2Bif(root, sourcePath)
    let sourceUri = documentUriFromPath(sourcePath)

    var initializeParams = newJObject()
    initializeParams["rootUri"] = %documentUriFromPath(root)
    initializeParams["capabilities"] = newJObject()

    var initializedParams = newJObject()
    var openDocument = newJObject()
    openDocument["uri"] = %sourceUri
    openDocument["languageId"] = %"nim"
    openDocument["version"] = %1
    openDocument["text"] = %source
    var openParams = newJObject()
    openParams["textDocument"] = openDocument

    var documentSymbolDocument = newJObject()
    documentSymbolDocument["uri"] = %sourceUri
    var documentSymbolParams = newJObject()
    documentSymbolParams["textDocument"] = documentSymbolDocument

    var workspaceSymbolParams = newJObject()
    workspaceSymbolParams["query"] = %"export"

    var hoverDocument = newJObject()
    hoverDocument["uri"] = %sourceUri
    var hoverPosition = newJObject()
    hoverPosition["line"] = %1
    hoverPosition["character"] = %6
    var hoverParams = newJObject()
    hoverParams["textDocument"] = hoverDocument
    hoverParams["position"] = hoverPosition

    var changedDocument = newJObject()
    changedDocument["uri"] = %sourceUri
    changedDocument["version"] = %2
    var changedParams = newJObject()
    changedParams["textDocument"] = changedDocument
    var changedContent = newJObject()
    changedContent["text"] =
      %"# phase 2 fixture\nproc renamed(): int = 1\nproc hidden(): int = 2\n"
    var changedContents = newJArray()
    changedContents.add(changedContent)
    changedParams["contentChanges"] = changedContents

    var changedSymbolDocument = newJObject()
    changedSymbolDocument["uri"] = %sourceUri
    var changedSymbolParams = newJObject()
    changedSymbolParams["textDocument"] = changedSymbolDocument

    var changedHoverParams = newJObject()
    changedHoverParams["textDocument"] = hoverDocument
    changedHoverParams["position"] = hoverPosition

    var messages: seq[string]
    messages.add(rpcRequest(1, "initialize", initializeParams))
    messages.add(rpcNotification("initialized", initializedParams))
    messages.add(rpcNotification("textDocument/didOpen", openParams))
    messages.add(rpcRequest(2, "textDocument/documentSymbol", documentSymbolParams))
    messages.add(rpcRequest(3, "workspace/symbol", workspaceSymbolParams))
    messages.add(rpcRequest(4, "textDocument/hover", hoverParams))
    messages.add(rpcNotification("textDocument/didChange", changedParams))
    messages.add(rpcRequest(5, "textDocument/documentSymbol", changedSymbolParams))
    messages.add(rpcRequest(6, "textDocument/hover", changedHoverParams))
    messages.add(rpcRequest(7, "shutdown", newJObject()))
    messages.add(rpcNotification("exit", newJObject()))

    let run = runServer(messages, @[root])
    check run.status == LspExitSuccess
    check run.responses.len == 7
    check run.responses[0]["result"]["capabilities"]["documentSymbolProvider"].getBool()
    check run.responses[0]["result"]["capabilities"]["workspaceSymbolProvider"].getBool()
    check run.responses[0]["result"]["capabilities"]["hoverProvider"].getBool()

    let documentSymbols = run.responses[1]["result"]
    check documentSymbols.kind == JArray
    check documentSymbols.len == 2
    check documentSymbols[0]["name"].getStr() == "exported"
    check documentSymbols[0]["location"]["uri"].getStr() == sourceUri
    check documentSymbols[0]["location"]["range"]["start"]["line"].getInt() == 1
    check documentSymbols[0]["location"]["range"]["start"]["character"].getInt() == 5
    check documentSymbols[0]["location"]["range"]["end"]["character"].getInt() == 13

    let workspaceSymbols = run.responses[2]["result"]
    check workspaceSymbols.len == 1
    check workspaceSymbols[0]["name"].getStr() == "exported"

    let hover = run.responses[3]["result"]
    check hover["contents"]["kind"].getStr() == "markdown"
    check hover["contents"]["value"].getStr().contains("exported")
    check hover["range"]["start"]["character"].getInt() == 5
    check hover["range"]["end"]["character"].getInt() == 13

    check run.responses[4]["id"].getInt() == 5
    check run.responses[4]["result"].len == 0
    check run.responses[5]["id"].getInt() == 6
    check run.responses[5]["result"].kind == JNull
    check run.responses[6]["id"].getInt() == 7

  test "does not present shim results and rejects ranged changes":
    let run = runServer(
      [
        """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}""",
        """{"jsonrpc":"2.0","method":"initialized","params":{}}""",
        """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/nimdex-phase1.nim","languageId":"nim","version":1,"text":"alpha"}}}""",
        """{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/nimdex-phase1.nim"},"position":{"line":0,"character":0}}}""",
        """{"jsonrpc":"2.0","id":3,"method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///tmp/nimdex-phase1.nim","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"text":"b"}]}}""",
        """{"jsonrpc":"2.0","id":4,"method":"shutdown"}""",
        """{"jsonrpc":"2.0","method":"exit"}""",
      ]
    )

    check run.status == LspExitSuccess
    check run.responses.len == 4
    check run.responses[1]["id"].getInt() == 2
    check run.responses[1]["error"]["code"].getInt() == LspAnalysisUnavailable
    check run.responses[2]["id"].getInt() == 3
    check run.responses[2]["error"]["code"].getInt() == -32602
    check run.responses[3]["id"].getInt() == 4

  test "rejects language requests before initialization":
    let run = runServer(
      [
        """{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/nimdex-phase1-sync.nim"},"position":{"line":0,"character":0}}}""",
        """{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{}}}""",
        """{"jsonrpc":"2.0","method":"exit"}""",
      ]
    )

    check run.status == LspExitFailure
    check run.responses.len == 2
    check run.responses[0]["error"]["code"].getInt() == LspServerNotInitialized
