import std/[os, unittest]

import nimdex/logsummary

suite "Bounded log summaries":
  test "shows only a few artifact names while preserving the total separately":
    let paths =
      @[
        "/cache/first.s.bif", "/cache/second.s.bif", "/cache/third.s.bif",
        "/cache/fourth.s.bif", "/cache/last.s.bif",
      ]
    check samplePaths(paths) == "first.s.bif, second.s.bif, third.s.bif, ..., last.s.bif"
    check samplePaths(paths[0 .. 1]) == "first.s.bif, second.s.bif"
    check samplePaths(newSeq[string]()) == "[]"

  test "correlates artifacts with one head cache subtree":
    let root = getTempDir() / "nimdex-log-cache"
    let head = root / "context" / "12345"
    check cacheRunId(root, @[head / "a.s.bif", head / "b.s.bif"]) == "12345"
    check cacheRunId(root, @[root / "context" / "overlays" / "12345" / "a.s.bif"]) ==
      "12345"
    check cacheRunId(root, @[head / "a.s.bif", root / "context" / "67890" / "b.s.bif"]) ==
      ""
    check cacheRunId(root, @[getTempDir() / "other" / "a.s.bif"]) == ""

  test "bounds multiline values":
    check logText("one\ntwo", 20) == "one two"
    check logText("abcdefghijkl", 5) == "abcde..."
    check logText("αβγ", 5) == "αβ..."
    check logFirstLine("version 2.3\nCompiled at yesterday") == "version 2.3"
    check logFirstLine("") == ""
