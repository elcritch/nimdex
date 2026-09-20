import std/[json, os, strutils, syncio, unittest]

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
        """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}""",
        """{"jsonrpc":"2.0","method":"initialized","params":{}}""",
        """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/nimdex-shim.nim","languageId":"nim","version":1,"text":"alpha"}}}""",
        """{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/nimdex-shim.nim"},"position":{"line":0,"character":0}}}""",
        """{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///tmp/nimdex-shim.nim","version":2},"contentChanges":[{"text":"beta"}]}}""",
        """{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/nimdex-shim.nim"},"position":{"line":0,"character":0}}}""",
        """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///tmp/nimdex-shim.nim"}}}""",
        """{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/nimdex-shim.nim"},"position":{"line":0,"character":0}}}""",
        """{"jsonrpc":"2.0","id":5,"method":"shutdown"}""",
        """{"jsonrpc":"2.0","method":"exit"}""",
      ]
    )

    check run.status == LspExitSuccess
    check run.responses.len == 5
    check run.responses[0]["id"].getInt() == 1
    check run.responses[0]["result"]["capabilities"]["textDocumentSync"]["openClose"].getBool()
    check run.responses[0]["result"]["capabilities"]["textDocumentSync"]["change"].getInt() ==
      1
    check run.responses[0]["result"]["capabilities"]["hoverProvider"].getBool()
    check run.responses[1]["result"]["contents"]["value"].getStr().contains("alpha")
    check run.responses[2]["result"]["contents"]["value"].getStr().contains(
      "Version: 2"
    )
    check run.responses[2]["result"]["contents"]["value"].getStr().contains("beta")
    check run.responses[3]["result"].kind == JNull
    check run.responses[4]["id"].getInt() == 5
    check run.responses[4]["result"].kind == JNull

  test "rejects language requests before initialization":
    let run = runServer(
      [
        """{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/nimdex-shim.nim"},"position":{"line":0,"character":0}}}""",
        """{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{}}}""",
        """{"jsonrpc":"2.0","method":"exit"}""",
      ]
    )

    check run.status == LspExitFailure
    check run.responses.len == 2
    check run.responses[0]["error"]["code"].getInt() == LspServerNotInitialized
