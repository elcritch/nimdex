import std/unittest

import sigils
import nimdex/language

suite "Nimdex asynchronous language runtime":
  test "correlates multiple submitted operations":
    let runtime = newLanguageRuntime(workers = 2, maxPending = 8)
    defer:
      runtime.close()

    let first = runtime.submit(
      LanguageRequest(
        kind: lrkOpen,
        uri: "file:///tmp/nimdex-phase3.nim",
        version: 1,
        text: "proc first() = discard",
      )
    )
    let second = runtime.submit(
      LanguageRequest(kind: lrkClose, uri: "file:///tmp/nimdex-phase3.nim")
    )
    check first != 0
    check second != 0
    check first != second

    var completions: seq[LanguageCompletion]
    while runtime.pendingCount() > 0:
      discard runtime.pump(Blocking)
      completions.add(runtime.takeCompleted())

    check completions.len == 2
    check completions[0].id == first
    check completions[1].id == second
    check completions[0].response.ok
    check completions[1].response.ok

  test "retains a cancellation reservation until the worker retires":
    let runtime = newLanguageRuntime(workers = 1, maxPending = 1)
    defer:
      runtime.close()

    let id =
      runtime.submit(LanguageRequest(kind: lrkWorkspaceSymbols, query: "cancelled"))
    check id != 0
    check runtime.submit(LanguageRequest(kind: lrkClose, uri: "file:///tmp/other.nim")) ==
      0
    check runtime.cancel(id)
    check runtime.abandon(id)
    check runtime.pendingCount() == 1

    while runtime.pendingCount() > 0:
      discard runtime.pump(Blocking)
      discard runtime.takeCompleted()
    check runtime.pendingCount() == 0
