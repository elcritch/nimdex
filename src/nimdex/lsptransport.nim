## Responsive LSP input for the Sigils JSON-RPC dispatcher.

import std/[json, syncio]

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
