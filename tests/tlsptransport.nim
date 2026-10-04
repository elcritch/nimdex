import std/[json, monotimes, nativesockets, net, strutils, unittest]

import nimdex/lsptransport

when defined(posix):
  from std/posix import SO_SNDBUF
else:
  var SO_SNDBUF {.importc, header: "<winsock2.h>".}: cint

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

suite "LSP TCP output":
  test "preserves framed responses across partial socket writes":
    let listener = newSocket(buffered = false)
    defer:
      listener.close()
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let client = newSocket(buffered = false)
    defer:
      client.close()
    client.connect("127.0.0.1", listener.getLocalAddr()[1])
    var server: Socket
    listener.accept(server)
    let io = newNimdexLspTcpIo(server)
    defer:
      io.stopIo()
    setSockOptInt(server.getFd(), SOL_SOCKET, SO_SNDBUF, 4096)
    io.startIo()
    let first = $(%*{"jsonrpc": "2.0", "id": 1, "result": "x".repeat(1024 * 1024)})
    let second = $(%*{"jsonrpc": "2.0", "id": 2, "result": "after partial write"})
    io.queueResponse(JsonRpcResponse(data: first))
    require io.hasPendingOutput()
    io.queueResponse(JsonRpcResponse(data: second))
    var parser = initJsonRpcFrameParser(DefaultNimdexMessageSize)
    var received: seq[string]
    let deadline = getMonoTime().ticks + 10_000_000_000'i64
    while received.len < 2 and getMonoTime().ticks < deadline:
      discard io.pollNimdexLspTcp(0)
      var readable = @[client.getFd()]
      if selectRead(readable, 1) > 0:
        var chunk = newString(16 * 1024)
        let count = client.recv(addr chunk[0], chunk.len)
        require count > 0
        chunk.setLen(count)
        parser.add(move(chunk))
        while true:
          let frame = parser.nextFrame()
          if frame.isNone():
            break
          received.add(frame.get())
    check received == @[first, second]
    check not io.hasPendingOutput()
