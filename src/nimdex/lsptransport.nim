## Responsive LSP input for the Sigils JSON-RPC dispatcher.

import std/[json, nativesockets, net, os, syncio]

import sigils
import sigils/rpcs/json/jrAgents
import sigils/rpcs/json/jrFraming

export jrAgents, jrFraming

const DefaultNimdexMessageSize* = 16 * 1024 * 1024
  ## Project graph reports and symbol responses can exceed Sigils' 1 MiB default.

proc boundedLspResponse*(
    response: sink JsonRpcResponse, maxMessageSize = DefaultNimdexMessageSize
): JsonRpcResponse =
  ## Settle oversized responses before the framed writer can throw. In
  ## particular, a writer exception must not unwind into joining an idle reader.
  if response.data.len <= maxMessageSize:
    return response
  let message = "Nimdex response exceeds the configured transport size limit"
  let payload = parseJson(response.data)
  var replacement: JsonNode
  if payload.kind == JObject and payload.hasKey("id"):
    replacement =
      %*{
        "jsonrpc": "2.0",
        "id": payload["id"],
        "error": {"code": -32603, "message": message},
      }
  else:
    replacement =
      %*{
        "jsonrpc": "2.0",
        "method": "window/logMessage",
        "params": {"type": 1, "message": message},
      }
  JsonRpcResponse(connectionId: response.connectionId, data: $replacement)

type NimdexLspStdioReader* = ref object of JsonRpcIoAgent
  ## A reader-only transport actor. Output is owned by the home thread.
  input: File
  parser: JsonRpcFrameParser
  maxMessageSize: int
  running: bool

type NimdexLspTcpIo* = ref object of JsonRpcIoAgent
  ## One Content-Length connection, read and written by the LSP home thread.
  socket: Socket
  parser: JsonRpcFrameParser
  maxMessageSize: int
  output: string
  outputOffset: int
  running: bool
  inputOpen: bool

proc containsExitRequest(data: string): bool =
  ## LSP's exit notification terminates the reader after its frame is queued.
  ## Keeping this check in the reader gives the owner an interruptible stop path
  ## even though File.readChar can block while stdin remains open.
  try:
    let root = parseJson(data)
    if root.kind == JObject:
      return
        root.hasKey("method") and root["method"].kind == JString and
        root["method"].getStr() == "exit"
    if root.kind == JArray:
      for item in root:
        if item.kind == JObject and item.hasKey("method") and
            item["method"].kind == JString and item["method"].getStr() == "exit":
          return true
  except CatchableError:
    discard

method startIo*(self: NimdexLspStdioReader) {.gcsafe.} =
  if self.isNil or self.running:
    return
  self.running = true
  emit self.jsonRpcStarted("stdio")
  try:
    while self.running:
      let frame = self.input.readJsonRpcMessage(self.parser)
      if frame.isNone():
        break
      let payload = frame.get()
      emit self.jsonRpcRequestReceived(
        JsonRpcRequest(connectionId: JsonRpcDefaultConnectionId, data: payload)
      )
      if payload.containsExitRequest():
        break
  except CatchableError:
    ## The home thread observes transport closure through jsonRpcStopped. A
    ## malformed or truncated frame must not strand language work on the
    ## reader thread.
    discard
  self.running = false
  emit self.jsonRpcStopped()

method stopIo*(self: NimdexLspStdioReader) {.gcsafe.} =
  if self.isNil or not self.running:
    return
  self.running = false
  emit self.jsonRpcStopped()

method queueResponse*(
    self: NimdexLspStdioReader, response: sink JsonRpcResponse
) {.gcsafe.} =
  ## Responses are serialized by the home-thread writer, never by this
  ## blocking reader actor.
  discard self
  discard response

proc newNimdexLspStdioReader*(
    input: File = stdin, maxMessageSize = DefaultNimdexMessageSize
): NimdexLspStdioReader =
  if input.isNil:
    raise newException(ValueError, "JSON-RPC input file must not be nil")
  if maxMessageSize <= 0:
    raise newException(ValueError, "JSON-RPC message size limit must be positive")
  NimdexLspStdioReader(
    input: input,
    parser: initJsonRpcFrameParser(maxMessageSize),
    maxMessageSize: maxMessageSize,
  )

proc finishInput(self: NimdexLspTcpIo) =
  if self.inputOpen:
    self.inputOpen = false
    emit self.jsonRpcStopped()

proc retrySocketOperation(error: OSErrorCode): bool =
  when defined(windows):
    error.int32 == WSAEWOULDBLOCK or error.int32 == WSAEINTR
  else:
    error.int32 == EAGAIN or error.int32 == EWOULDBLOCK or error.int32 == EINTR

method startIo*(self: NimdexLspTcpIo) {.gcsafe.} =
  if not self.running:
    self.running = true
    self.inputOpen = true
    emit self.jsonRpcStarted("tcp")

method stopIo*(self: NimdexLspTcpIo) {.gcsafe.} =
  self.finishInput()
  self.running = false
  self.socket.close()

proc flushOutput(self: NimdexLspTcpIo) =
  if self.running and self.outputOffset < self.output.len:
    let sent = self.socket.send(
      unsafeAddr self.output[self.outputOffset], self.output.len - self.outputOffset
    )
    if sent > 0:
      self.outputOffset += sent
      if self.outputOffset == self.output.len:
        self.output.setLen(0)
        self.outputOffset = 0
    elif sent == 0 or not retrySocketOperation(osLastError()):
      self.stopIo()

method queueResponse*(self: NimdexLspTcpIo, response: sink JsonRpcResponse) {.gcsafe.} =
  if self.running:
    let frame = frameJsonRpcMessage(response.data, self.maxMessageSize)
    # Bound queued output when a peer stops reading while analysis continues.
    if self.output.len - self.outputOffset + frame.len > 4 * self.maxMessageSize:
      self.stopIo()
    else:
      if self.outputOffset > 0:
        self.output = self.output[self.outputOffset .. ^1]
        self.outputOffset = 0
      self.output.add(frame)
      self.flushOutput()

proc hasPendingOutput*(self: NimdexLspTcpIo): bool =
  ## Return whether the connected peer still has framed output to receive.
  self.running and self.outputOffset < self.output.len

proc pollNimdexLspTcp*(self: NimdexLspTcpIo, timeoutMs = 10): bool =
  ## Dispatch available frames and flush output without blocking worker completion.
  ## Return false after a socket failure; EOF is signalled through jsonRpcStopped.
  self.flushOutput()
  if self.running and self.inputOpen:
    var readable = @[self.socket.getFd()]
    let ready = selectRead(readable, timeoutMs)
    if ready < 0:
      if not retrySocketOperation(osLastError()):
        self.stopIo()
    elif ready > 0:
      var chunk = newString(JsonRpcFrameReadSize)
      let received = self.socket.recv(addr chunk[0], chunk.len)
      if received == 0:
        self.finishInput()
      elif received < 0:
        if not retrySocketOperation(osLastError()):
          self.stopIo()
      else:
        chunk.setLen(received)
        self.parser.add(move(chunk))
        try:
          while self.inputOpen:
            let frame = self.parser.nextFrame()
            if frame.isNone():
              break
            let payload = frame.get()
            emit self.jsonRpcRequestReceived(
              JsonRpcRequest(connectionId: JsonRpcDefaultConnectionId, data: payload)
            )
            if payload.containsExitRequest():
              self.finishInput()
        except JsonRpcFrameError:
          self.finishInput()
  elif self.hasPendingOutput() and timeoutMs > 0:
    var writable = @[self.socket.getFd()]
    discard selectWrite(writable, timeoutMs)
  self.running

proc newNimdexLspTcpIo*(
    socket: Socket, maxMessageSize = DefaultNimdexMessageSize
): NimdexLspTcpIo =
  ## Take ownership of an unbuffered socket. stopIo closes it on the home thread.
  if socket.isNil:
    raise newException(ValueError, "LSP TCP socket must not be nil")
  if maxMessageSize <= 0:
    raise newException(ValueError, "JSON-RPC message size limit must be positive")
  socket.getFd().setBlocking(false)
  when defined(macosx):
    setSockOptInt(socket.getFd(), SOL_SOCKET, SO_NOSIGPIPE, 1)
  NimdexLspTcpIo(
    socket: socket,
    parser: initJsonRpcFrameParser(maxMessageSize),
    maxMessageSize: maxMessageSize,
  )
