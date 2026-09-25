## Bounded, length-prefixed messages for the local CLI service.

import std/net

const MaxCliMessageSize* = 32 * 1024 * 1024

proc receiveExact(socket: Socket, size: int, timeoutMs: int): string =
  result = newString(size)
  var offset = 0
  while offset < size:
    let received =
      if timeoutMs < 0:
        socket.recv(addr result[offset], size - offset)
      else:
        socket.recv(addr result[offset], size - offset, timeoutMs)
    if received <= 0:
      raise
        newException(IOError, "CLI connection closed before the message was complete")
    offset += received

proc receiveCliMessage*(socket: Socket, timeoutMs = -1): string =
  let header = socket.receiveExact(4, timeoutMs)
  let size =
    (ord(header[0]) shl 24) or (ord(header[1]) shl 16) or (ord(header[2]) shl 8) or
    ord(header[3])
  if size <= 0 or size > MaxCliMessageSize:
    raise newException(IOError, "invalid CLI message size: " & $size)
  socket.receiveExact(size, timeoutMs)

proc sendExact(socket: Socket, message: string) =
  var offset = 0
  while offset < message.len:
    let sent = socket.send(unsafeAddr message[offset], message.len - offset)
    if sent <= 0:
      raise newException(IOError, "CLI connection closed while sending a message")
    offset += sent

proc sendCliMessage*(socket: Socket, message: string) =
  if message.len == 0 or message.len > MaxCliMessageSize:
    raise newException(IOError, "invalid CLI message size: " & $message.len)
  var header = newString(4)
  header[0] = chr((message.len shr 24) and 255)
  header[1] = chr((message.len shr 16) and 255)
  header[2] = chr((message.len shr 8) and 255)
  header[3] = chr(message.len and 255)
  socket.sendExact(header)
  socket.sendExact(message)
