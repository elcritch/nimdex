import std/[os, unittest]

import nimdex/clicapture

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
