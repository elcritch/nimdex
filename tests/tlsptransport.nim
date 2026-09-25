import std/[json, strutils, unittest]

import nimdex/lsptransport

suite "Large LSP responses":
  test "accepts project reports above the generic framing default":
    let data = $(%*{"jsonrpc": "2.0", "id": 1, "result": "x".repeat(1024 * 1024)})
    let response = boundedLspResponse(JsonRpcResponse(data: data))
    var parser = initJsonRpcFrameParser(DefaultNimdexMessageSize)
    parser.add(frameJsonRpcMessage(response.data, DefaultNimdexMessageSize))
    check parser.nextFrame().get() == data

  test "settles an oversized request with its original id":
    let data = $(%*{"jsonrpc": "2.0", "id": "large", "result": "x".repeat(2048)})
    let response = boundedLspResponse(JsonRpcResponse(connectionId: 8, data: data), 512)
    check response.connectionId == 8
    let parsed = parseJson(response.data)
    check parsed["id"].getStr() == "large"
    check parsed["error"]["code"].getInt() == -32603
    check frameJsonRpcMessage(response.data, 512).len > 0

  test "reports an oversized notification without creating a response id":
    let data =
      $(
        %*{
          "jsonrpc": "2.0",
          "method": "textDocument/publishDiagnostics",
          "params": {"message": "x".repeat(2048)},
        }
      )
    let response = boundedLspResponse(JsonRpcResponse(data: data), 512)
    let parsed = parseJson(response.data)
    check not parsed.hasKey("id")
    check parsed["method"].getStr() == "window/logMessage"
