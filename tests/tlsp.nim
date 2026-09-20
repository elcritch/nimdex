import std/[json, os, syncio, unittest]

import nimdex/lsp
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
    messages: openArray[string]
): tuple[status: int, responses: seq[JsonNode]] =
  let suffix = $getCurrentProcessId()
  let
    inputPath = getTempDir() / ("nimdex-lsp-input-" & suffix & ".json")
    outputPath = getTempDir() / ("nimdex-lsp-output-" & suffix & ".json")
  writeFile(inputPath, framed(messages))

  var input = open(inputPath, fmRead)
  var output = open(outputPath, fmWrite)
  try:
    result.status = runNimdexLspStdio(input, output, workers = 1)
  finally:
    input.close()
    output.close()

  try:
    result.responses = readResponses(outputPath)
  finally:
    removeFile(inputPath)
    removeFile(outputPath)

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
