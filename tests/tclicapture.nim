import std/[os, osproc, streams, strutils, unittest]

import nimdex/clicapture

type CaptureJob = object
  source: Stream
  path: string

proc runCapture(job: ptr CaptureJob) {.thread.} =
  var log = initRollingLog(job.path)
  job.source.captureStream(log)
  log.close()

suite "CLI log capture":
  test "retains recent output in two bounded temporary files":
    let path = getTempDir() / ("nimdex-capture-test-" & $getCurrentProcessId())
    defer:
      if fileExists(path):
        removeFile(path)
      if fileExists(path & ".1"):
        removeFile(path & ".1")
    var log = initRollingLog(path, maxBytes = 10)
    log.write("first\n")
    log.write("second\n")
    log.close()
    check readFile(path & ".1") == "first\n"
    check readFile(path) == "second\n"
    check log.rotations == 1
    check log.totalBytes == 13

  when defined(posix):
    test "publishes a short log line while the child is still running":
      let path = getTempDir() / ("nimdex-live-capture-" & $getCurrentProcessId())
      let child = startProcess(
        "/bin/sh",
        args = ["-c", "printf 'ready\\n' >&2; read waiting"],
        options = {poUsePath, poInteractive},
      )
      var job = CaptureJob(source: child.errorStream(), path: path)
      var thread: Thread[ptr CaptureJob]
      createThread(thread, runCapture, addr job)
      defer:
        if child.running():
          child.kill()
        discard child.waitForExit()
        joinThread(thread)
        child.close()
        if fileExists(path):
          removeFile(path)
      var captured = false
      for attempt in 0 ..< 200:
        if fileExists(path) and readFile(path).contains("ready\n"):
          captured = true
          break
        sleep(10)
      check captured
      check child.running()
