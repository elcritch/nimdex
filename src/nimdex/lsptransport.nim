## Responsive LSP input for the Sigils JSON-RPC dispatcher.

import std/[json, syncio]

import sigils
import sigils/rpcs/json/jrAgents
import sigils/rpcs/json/jrFraming

export jrAgents, jrFraming

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
    input: File = stdin, maxMessageSize = DefaultJsonRpcMaxMessageSize
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
