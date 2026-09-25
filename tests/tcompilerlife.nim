import std/[monotimes, os, osproc, strutils, tempfiles, times, unittest]
import nimdex/[compiler, documents, workspace]

const Compiler = currentSourcePath.parentDir.parentDir / "deps/nim-devel/bin/nim"

when defined(posix):
  proc cancelWhenStarted(
      args: tuple[token: CompilerCancellation, marker: string]
  ) {.thread.} =
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while not fileExists(args.marker) and getMonoTime() < deadline:
      sleep(10)
    args.token.cancelCompiler()

  suite "compiler process lifetime":
    test "cancels a compiler blocked in a compile-time child process":
      let root = normalizeDocumentPath(createTempDir("nimdex-cancel-", ""))
      defer:
        removeDir(root)
      writeFile(
        root / "sleeper.sh", "#!/bin/sh\nsleep 30 &\necho $! > child.started\nwait\n"
      )
      let source = root / "main.nim"
      writeFile(source, "static: discard staticExec(\"sh ./sleeper.sh\")\n")
      let workspace = initWorkspace(
        documentUriFromPath(root),
        entryPoints = @[source],
        compilerPath = Compiler,
        cacheRoot = root / "cache",
      )
      let capabilities = probeCompiler(Compiler)
      let cancellation = newCompilerCancellation()
      defer:
        cancellation.releaseCompilerCancellation()
      var canceller: Thread[tuple[token: CompilerCancellation, marker: string]]
      createThread(canceller, cancelWhenStarted, (cancellation, root / "child.started"))
      let started = getMonoTime()
      let refresh = runCompilerRefresh(
        CompilerRefreshRequest(
          workspace: workspace, capabilities: capabilities, cancellation: cancellation
        )
      )
      canceller.joinThread()
      check fileExists(root / "child.started")
      check refresh.cancelled
      check (getMonoTime() - started).inSeconds < 6
      if fileExists(root / "child.started"):
        let child = parseInt(readFile(root / "child.started").strip())
        let state = execProcess("ps -o stat= -p " & $child).strip()
        # A zombie is already terminated, pending adoption/reaping by init.
        check state.len == 0 or state.startsWith("Z")
