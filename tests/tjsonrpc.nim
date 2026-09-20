import std/[json, options, os, syncio, unittest]

import nimdex/jsonrpc
import sigils
import sigils/rpcs/jsonrpc
import sigils/rpcs/json/jrFraming

proc writeRequest(path, request: string) =
  writeFile(path, frameJsonRpcMessage(request))

suite "nimdex JSON-RPC stdio server":
  test "registers the greet operation":
    startLocalThreadDefault()
    let adapter = newNimdexJsonRpcAdapter()
    let encoded = adapter.handleJsonRpc(
      """{"jsonrpc":"2.0","method":"nimdex.greet","params":{"name":"Nim"},"id":1}"""
    )

    check encoded.isSome()
    let response = parseJson(encoded.get())
    check response["result"].getStr() == "hello, Nim"
    check response["id"].getInt() == 1

  test "serves Content-Length requests over stdio":
    let
      inputPath = getTempDir() / "nimdex-jsonrpc-input.json"
      outputPath = getTempDir() / "nimdex-jsonrpc-output.json"
      request =
        """{"jsonrpc":"2.0","method":"nimdex.greet","params":["stdio"],"id":"request-1"}"""

    writeRequest(inputPath, request)
    var input = open(inputPath, fmRead)
    var output = open(outputPath, fmWrite)
    try:
      runNimdexJsonRpcStdio(input, output)
    finally:
      input.close()
      output.close()

    try:
      var parser = initJsonRpcFrameParser()
      parser.add(readFile(outputPath))
      let frame = parser.nextFrame()
      check frame.isSome()

      let response = parseJson(frame.get())
      check response["result"].getStr() == "hello, stdio"
      check response["id"].getStr() == "request-1"
      check not parser.hasPendingData()
    finally:
      removeFile(inputPath)
      removeFile(outputPath)
