## Bounded temporary logs for CLI daemon and compiler diagnostics.

import std/[os, streams, syncio]

const DefaultCliLogBytes* = 8 * 1024 * 1024

type RollingLog* = object
  path*: string
  file: File
  maxBytes: int
  currentBytes: int
  totalBytes*: int
  rotations*: int

proc initRollingLog*(path: string, maxBytes = DefaultCliLogBytes): RollingLog =
  if maxBytes <= 0:
    raise newException(ValueError, "log size limit must be positive")
  var file: File
  if not open(file, path, fmWrite):
    raise newException(IOError, "could not open log file: " & path)
  RollingLog(path: path, file: file, maxBytes: maxBytes)

proc rotate(log: var RollingLog) =
  log.file.close()
  let previous = log.path & ".1"
  if fileExists(previous):
    removeFile(previous)
  moveFile(log.path, previous)
  if not open(log.file, log.path, fmWrite):
    raise newException(IOError, "could not reopen log file: " & log.path)
  log.currentBytes = 0
  inc log.rotations

proc write*(log: var RollingLog, text: string) =
  if text.len == 0:
    return
  log.totalBytes += text.len
  let retained =
    if text.len > log.maxBytes:
      text[text.len - log.maxBytes .. ^1]
    else:
      text
  if log.currentBytes + retained.len > log.maxBytes:
    log.rotate()
  log.file.write(retained)
  log.file.flushFile()
  log.currentBytes += retained.len

type CaptureLineHandler* = proc(line: string, context: pointer) {.nimcall, gcsafe.}

proc captureStream*(
    source: Stream,
    log: var RollingLog,
    onLine: CaptureLineHandler = nil,
    context: pointer = nil,
) =
  ## Process pipes are buffered FileStreams: a bulk read may wait until its
  ## entire requested size arrives. Publish each complete log line promptly.
  var pending = newStringOfCap(4096)
  while true:
    let character = source.readChar()
    if character == '\0':
      break
    pending.add(character)
    if character == '\n' or pending.len >= 4096:
      log.write(pending)
      if not onLine.isNil:
        onLine(pending, context)
      pending.setLen(0)
  if pending.len > 0:
    log.write(pending)
    if not onLine.isNil:
      onLine(pending, context)

proc close*(log: var RollingLog) =
  if not log.file.isNil:
    log.file.close()
    log.file = nil
