import std/[assertions, json, net, os, osproc, streams, strutils]

import nimdex/cli
import nimdex/clicapture
import nimdex/cliipc
import nimdex/documents
import sigils/rpcs/json/jrFraming

when defined(posix):
  import std/posix

const FixtureRoot = currentSourcePath.parentDir / "fixtures/binny_phase0"

var testDaemonPath: string

type CapturedErrors = object
  stream: Stream
  path: string

proc captureProtocolErrors(state: ptr CapturedErrors) {.thread.} =
  var log = initRollingLog(state.path)
  try:
    state.stream.captureStream(log)
  finally:
    log.close()

proc drainProtocolErrors(stream: Stream) {.thread.} =
  while not stream.atEnd():
    discard stream.readLine()

proc readListenerPort(stream: Stream): string =
  var ready = false
  while not stream.atEnd():
    let line = stream.readLine()
    if line.contains("Nimdex CLI listener ready"):
      ready = true
    if ready:
      let marker = "127.0.0.1:"
      let start = line.find(marker)
      if start >= 0:
        for character in line[start + marker.len .. ^1]:
          if character notin {'0' .. '9'}:
            break
          result.add(character)
        if result.len > 0:
          return
  raise newException(IOError, "daemon exited before logging its listener port")

proc sendProtocol(process: Process, methodName: string, params: JsonNode, id = 0) =
  var message = %*{"jsonrpc": "2.0", "method": methodName, "params": params}
  if id != 0:
    message["id"] = %id
  process.inputStream().write(frameJsonRpcMessage($message))
  process.inputStream().flush()

proc receiveProtocol(
    process: Process, id: int, notifications: var seq[JsonNode]
): JsonNode =
  var parser = initJsonRpcFrameParser()
  let stream = process.outputStream()
  while not stream.atEnd():
    parser.add($stream.readChar())
    let frame = parser.nextFrame()
    if frame.isSome():
      let message = parseJson(frame.get())
      if message.hasKey("id"):
        doAssert message["id"].getInt() == id
        return message
      notifications.add(message)
  raise newException(IOError, "daemon exited before replying")

proc testDaemon(): string =
  if testDaemonPath.len > 0:
    return testDaemonPath
  let repositoryRoot = currentSourcePath.parentDir.parentDir
  testDaemonPath = getTempDir() / ("nimdex-cli-daemon-" & $getCurrentProcessId())
  let nimCache = getTempDir() / ("nimdex-cli-daemon-cache-" & $getCurrentProcessId())
  let compiler = repositoryRoot / "deps/nim-devel/bin/nim"
  doAssert compiler.len > 0
  let compilerOutput = execProcess(
    compiler,
    workingDir = repositoryRoot,
    args = [
      "c",
      "--hints:off",
      "--warnings:off",
      "--nimcache:" & nimCache,
      "--out:" & testDaemonPath,
      repositoryRoot / "src/nimdex.nim",
    ],
    options = {poUsePath, poStdErrToStdOut},
  )
  doAssert fileExists(testDaemonPath), compilerOutput
  testDaemonPath

proc runCli(args: openArray[string]): tuple[status: int, output, errors: string] =
  let suffix = $getCurrentProcessId()
  let
    outputPath = getTempDir() / ("nimdex-cli-output-" & suffix & ".txt")
    errorPath = getTempDir() / ("nimdex-cli-error-" & suffix & ".txt")
  var outputFile = open(outputPath, fmWrite)
  var errorFile = open(errorPath, fmWrite)
  try:
    result.status = runNimdexCli(args, outputFile, errorFile)
  finally:
    outputFile.close()
    errorFile.close()
  result.output = readFile(outputPath)
  result.errors = readFile(errorPath)
  removeFile(outputPath)
  removeFile(errorPath)

proc runExternalCli(args: openArray[string]): tuple[status: int, output: string] =
  let repositoryRoot = currentSourcePath.parentDir.parentDir
  var process = startProcess(
    testDaemon(),
    workingDir = repositoryRoot,
    args = args,
    options = {poUsePath, poStdErrToStdOut},
  )
  result.output = process.outputStream().readAll()
  result.status = process.waitForExit()
  process.close()

block cli_help:
  let run = runCli(["help"])
  doAssert run.status == 0
  doAssert run.output.contains("Usage: nimdex")
  doAssert run.output.contains("symbols")

block cli_frontend_validation:
  let run = runCli(["check", "--frontend", "unknown"])
  doAssert run.status == 2
  doAssert run.errors.contains("--frontend must be compile, track, or ic")
  let ic = runCli(["check", "--connect", "49152", "--frontend", "ic"])
  doAssert ic.status == 2
  doAssert ic.errors.contains("set analysis options when starting")

block cli_connection_validation:
  let run = runCli(["check", "--connect", "0"])
  doAssert run.status == 2
  doAssert run.errors.contains("--connect requires a valid port")
  let options = runCli(["check", "--connect", "49152", "--frontend", "track"])
  doAssert options.status == 2
  doAssert options.errors.contains("set analysis options when starting")

block interactive_head_loading:
  let root = normalizeDocumentPath(
    getTempDir() / ("nimdex-stdio-heads-" & $getCurrentProcessId())
  )
  createDir(root)
  defer:
    removeDir(root)
  let good = root / "a.nim"
  let bad = root / "b.nim"
  writeFile(good, "const healthy* = 1\n")
  writeFile(bad, "proc broken( = discard\n")
  let compiler = currentSourcePath.parentDir.parentDir / "deps/nim-devel/bin/nim"
  let process = startProcess(
    testDaemon(), args = ["daemon", "--frontend", "track"], options = {poUsePath}
  )
  var errorThread: Thread[Stream]
  createThread(errorThread, drainProtocolErrors, process.errorStream())
  defer:
    if process.running():
      process.sendProtocol("exit", %*{})
    if process.waitForExit(10000) == -1:
      process.kill()
      discard process.waitForExit()
    joinThread(errorThread)
    process.close()
  var notifications: seq[JsonNode]
  process.sendProtocol(
    "initialize",
    %*{
      "rootUri": documentUriFromPath(root),
      "capabilities": {},
      "initializationOptions": {"compilerPath": compiler, "entryPoints": [good, bad]},
    },
    1,
  )
  doAssert process.receiveProtocol(1, notifications).hasKey("result")
  process.sendProtocol("initialized", %*{})
  process.sendProtocol(
    "textDocument/documentSymbol",
    %*{"textDocument": {"uri": documentUriFromPath(good)}},
    2,
  )
  let document = process.receiveProtocol(2, notifications)
  doAssert document["result"][0]["name"].getStr() == "healthy"
  process.sendProtocol("workspace/symbol", %*{"query": "healthy"}, 3)
  let workspace = process.receiveProtocol(3, notifications)
  doAssert workspace["result"].len == 1
  process.sendProtocol(
    "textDocument/documentSymbol",
    %*{"textDocument": {"uri": documentUriFromPath(bad)}},
    4,
  )
  doAssert process.receiveProtocol(4, notifications)["error"]["code"].getInt() == -32001
  var badDiagnostic = false
  for message in notifications:
    if message["method"].getStr() == "textDocument/publishDiagnostics" and
        message["params"]["uri"].getStr() == documentUriFromPath(bad) and
        message["params"]["diagnostics"].len > 0:
      badDiagnostic = true
  doAssert badDiagnostic
  process.sendProtocol("shutdown", %*{}, 5)
  discard process.receiveProtocol(5, notifications)
  process.sendProtocol("exit", %*{})

block cli_symbols:
  let cacheRoot = getTempDir() / ("nimdex-cli-cache-" & $getCurrentProcessId())
  let run = runExternalCli(
    ["symbols", FixtureRoot, "exportedRoutine", "--cache-root", cacheRoot]
  )
  doAssert run.status == 0, run.output
  doAssert run.output.contains("exportedRoutine")
  doAssert run.output.contains("Nim compiler starting"), run.output
  doAssert run.output.contains("Nim compiler done"), run.output
  doAssert run.output.contains("Nim compiler progress"), run.output
  doAssert run.output.find("Nim compiler starting") <
    run.output.find("Nim compiler done")
  doAssert run.output.find("Nim compiler done") <
    run.output.find("Nim compiler progress")
  doAssert run.output.contains("-compile.log"), run.output
  var listedHidden = false
  for line in run.output.splitLines:
    if line.endsWith(" hiddenRoutine"):
      listedHidden = true
  doAssert not listedHidden

block cli_debug:
  let cacheRoot = getTempDir() / ("nimdex-cli-debug-cache-" & $getCurrentProcessId())
  let run = runExternalCli(
    ["debug", FixtureRoot, "--cache-root", cacheRoot, "--frontend", "track"]
  )
  doAssert run.status == 0, run.output
  doAssert run.output.contains("\"compiler\"")
  doAssert run.output.contains("\"artifactPaths\"")
  doAssert run.output.contains("\"tokenCount\"")
  doAssert run.output.contains("\"frontend\": \"track\"")

block cli_ic_debug:
  let cacheRoot = getTempDir() / ("nimdex-cli-ic-cache-" & $getCurrentProcessId())
  let run = runExternalCli(
    ["debug", FixtureRoot, "--cache-root", cacheRoot, "--frontend", "ic"]
  )
  doAssert run.status == 0, run.output
  doAssert run.output.contains("\"frontend\": \"ic\"")
  doAssert run.output.contains("\"artifactPaths\"")

block cli_package_layout:
  let root = getTempDir() / ("nimdex-cli-layout-" & $getCurrentProcessId())
  createDir(root / "src")
  createDir(root / "tests")
  defer:
    removeDir(root)
  writeFile(root / "sample.nimble", "srcDir = \"src\"\n")
  writeFile(root / "src/sample.nim", "proc packageValue*(): int = 1\n")
  writeFile(root / "tests/tpackage.nim", "import sample\ndiscard packageValue()\n")
  let run = runExternalCli(["debug", root])
  doAssert run.status == 0, run.output
  doAssert run.output.contains("\"actualHeads\"")
  doAssert run.output.contains("tpackage.nim")

block eager_nimble_loading:
  let root = getTempDir() / ("nimdex-cli-eager-" & $getCurrentProcessId())
  createDir(root / "src")
  defer:
    removeDir(root)
  writeFile(root / "sample.nimble", "srcDir = \"src\"\n")
  writeFile(root / "src/sample.nim", "proc sample*() = discard\n")
  let path = getTempDir() / ("nimdex-cli-eager-log-" & $getCurrentProcessId())
  let process = startProcess(
    testDaemon(),
    workingDir = root,
    args = ["daemon"],
    options = {poUsePath, poInteractive},
  )
  var state = CapturedErrors(stream: process.errorStream(), path: path)
  var thread: Thread[ptr CapturedErrors]
  createThread(thread, captureProtocolErrors, addr state)
  defer:
    if process.running():
      process.kill()
    discard process.waitForExit()
    joinThread(thread)
    process.close()
    if fileExists(path):
      removeFile(path)
  var discovered = false
  for attempt in 0 ..< 200:
    if fileExists(path) and
        readFile(path).contains("Discovered Nimble project at startup"):
      discovered = true
      break
    sleep(10)
  doAssert discovered
  doAssert process.running()
  createDir(root / "other")
  writeFile(root / "other/sample.nim", "proc other*() = discard\n")
  writeFile(root / "sample.nimble", "srcDir = \"other\"\n")
  var notifications: seq[JsonNode]
  process.sendProtocol(
    "initialize",
    %*{
      "rootUri": documentUriFromPath(root),
      "capabilities": {},
      "initializationOptions": {"autoCompile": false},
    },
    1,
  )
  doAssert process.receiveProtocol(1, notifications).hasKey("result")
  process.sendProtocol("initialized", %*{})
  process.sendProtocol("nimdex/debug", %*{}, 2)
  let debug = process.receiveProtocol(2, notifications)
  doAssert debug["result"]["workspace"]["importPaths"][0].getStr() ==
    normalizeDocumentPath(root / "other")

block cli_diagnostic_capture:
  let root = getTempDir() / ("nimdex-cli-diagnostics-" & $getCurrentProcessId())
  createDir(root)
  defer:
    removeDir(root)
  let broken = root / "broken.nim"
  writeFile(broken, "proc broken( = discard\n")
  let run = runExternalCli(["check", root, "--entry-point", broken])
  doAssert run.status != 0, run.output
  doAssert run.output.contains("Nim compiler done"), run.output
  doAssert run.output.contains("exitCode"), run.output
  doAssert run.output.contains("Compiler diagnostics captured"), run.output
  doAssert run.output.contains(".diagnostics.log"), run.output
  doAssert not run.output.contains("nimdex: file://"), run.output

when defined(posix):
  block cli_compiler_heartbeat:
    let root = getTempDir() / ("nimdex-cli-slow-" & $getCurrentProcessId())
    createDir(root)
    defer:
      removeDir(root)
    let source = root / "main.nim"
    let wrapper = root / "slow-nim"
    let compiler = currentSourcePath.parentDir.parentDir / "deps/nim-devel/bin/nim"
    writeFile(source, "const answer* = 42\n")
    writeFile(
      wrapper,
      "#!/bin/sh\ncase \"$1\" in --version|--fullhelp) ;; *) sleep 6 ;; esac\n" & "exec " &
        quoteShell(compiler) & " \"$@\"\n",
    )
    setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
    let run = runExternalCli(
      ["check", root, "--compiler", wrapper, "--cache-root", root / "cache"]
    )
    doAssert run.status == 0, run.output
    let starting = run.output.find("Nim compiler starting")
    let heartbeat = run.output.find("Nim compiler still running")
    let done = run.output.find("Nim compiler done")
    doAssert starting >= 0 and starting < heartbeat, run.output
    doAssert heartbeat < done, run.output
    doAssert run.output.contains("Nim compiler still running"), run.output
    doAssert run.output.contains("elapsedSeconds"), run.output
    doAssert run.output.contains("elapsedMilliseconds"), run.output

block persistent_cli_service:
  let repositoryRoot = currentSourcePath.parentDir.parentDir
  let compiler = repositoryRoot / "deps/nim-devel/bin/nim"
  let cacheRoot = getTempDir() / ("nimdex-cli-service-cache-" & $getCurrentProcessId())
  let process = startProcess(
    testDaemon(),
    args = [
      "daemon", FixtureRoot, "--listen", "0", "--compiler", compiler, "--cache-root",
      cacheRoot,
    ],
    options = {poUsePath},
  )
  let port = process.errorStream().readListenerPort()
  var errorThread: Thread[Stream]
  createThread(errorThread, drainProtocolErrors, process.errorStream())
  defer:
    if process.running():
      process.kill()
      discard process.waitForExit()
    joinThread(errorThread)
    process.close()

  let checked = runExternalCli(["check", FixtureRoot, "--connect", port])
  doAssert checked.status == 0, checked.output
  doAssert checked.output.contains("modules:")

  let aborted = newSocket()
  aborted.connect("127.0.0.1", Port(parseInt(port)))
  aborted.send("\x00\x00")
  aborted.close()

  let symbols = runExternalCli(
    ["symbols", FixtureRoot, "--connect", port, "--query", "exportedRoutine"]
  )
  doAssert symbols.status == 0, symbols.output
  doAssert symbols.output.contains("exportedRoutine")

  let debug = runExternalCli(["debug", FixtureRoot, "--connect", port])
  doAssert debug.status == 0, debug.output
  doAssert debug.output.contains("\"actualHeads\"")

  let wrongRoot = runExternalCli(["check", repositoryRoot, "--connect", port])
  doAssert wrongRoot.status == 1, wrongRoot.output
  doAssert wrongRoot.output.contains("daemon serves")

  let stopped = runExternalCli(["stop", "--connect", port])
  doAssert stopped.status == 0, stopped.output
  doAssert stopped.output.contains("nimdex daemon stopped")
  doAssert process.waitForExit(10000) == 0
  doAssert process.outputStream().readAll().len == 0

  let restarted = startProcess(
    testDaemon(),
    args = [
      "daemon", FixtureRoot, "--listen", "0", "--compiler", compiler, "--cache-root",
      cacheRoot,
    ],
    options = {poUsePath},
  )
  let restartedPort = restarted.errorStream().readListenerPort()
  var restartedErrors: Thread[Stream]
  createThread(restartedErrors, drainProtocolErrors, restarted.errorStream())
  defer:
    if restarted.running():
      restarted.kill()
      discard restarted.waitForExit()
    joinThread(restartedErrors)
    restarted.close()
  let reused = runExternalCli(["debug", FixtureRoot, "--connect", restartedPort])
  doAssert reused.status == 0, reused.output
  doAssert reused.output.contains("\"compiledHeads\": 0"), reused.output
  doAssert reused.output.contains("\"restoredHeads\": 1"), reused.output
  let restopped = runExternalCli(["stop", "--connect", restartedPort])
  doAssert restopped.status == 0, restopped.output
  doAssert restarted.waitForExit(10000) == 0

when defined(posix):
  block cli_service_signals:
    let repositoryRoot = currentSourcePath.parentDir.parentDir
    let compiler = repositoryRoot / "deps/nim-devel/bin/nim"
    for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT]:
      block signal_case:
        let process = startProcess(
          testDaemon(),
          args = ["daemon", FixtureRoot, "--listen", "0", "--compiler", compiler],
          options = {poUsePath},
        )
        let port = process.errorStream().readListenerPort()
        var errorThread: Thread[Stream]
        createThread(errorThread, drainProtocolErrors, process.errorStream())
        defer:
          if process.running():
            process.kill()
            discard process.waitForExit()
          joinThread(errorThread)
          process.close()
        if signalNumber == SIGTERM:
          let partialClient = newSocket()
          partialClient.connect("127.0.0.1", Port(parseInt(port)))
          partialClient.send("\x00\x00")
          defer:
            partialClient.close()
          sleep(100)
        doAssert posix.kill(Pid(process.processID()), signalNumber) == 0
        doAssert process.waitForExit(10000) == 0
        let rebound = newSocket()
        defer:
          rebound.close()
        rebound.bindAddr(Port(parseInt(port)), "127.0.0.1")

  block cli_service_signal_during_request:
    let repositoryRoot = currentSourcePath.parentDir.parentDir
    let compiler = repositoryRoot / "deps/nim-devel/bin/nim"
    let root = normalizeDocumentPath(
      getTempDir() / ("nimdex-cli-signal-request-" & $getCurrentProcessId())
    )
    createDir(root)
    defer:
      removeDir(root)
    writeFile(root / "main.nim", "const answer* = 42\n")
    let wrapper = root / "slow-nim"
    writeFile(
      wrapper,
      "#!/bin/sh\ncase \"$1\" in --version|--fullhelp) ;; *) sleep 6 ;; esac\n" & "exec " &
        quoteShell(compiler) & " \"$@\"\n",
    )
    setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
    let process = startProcess(
      testDaemon(),
      args = ["daemon", root, "--listen", "0", "--compiler", wrapper],
      options = {poUsePath},
    )
    let port = process.errorStream().readListenerPort()
    var errorThread: Thread[Stream]
    createThread(errorThread, drainProtocolErrors, process.errorStream())
    defer:
      if process.running():
        process.kill()
        discard process.waitForExit()
      joinThread(errorThread)
      process.close()
    let client = newSocket()
    defer:
      client.close()
    client.connect("127.0.0.1", Port(parseInt(port)))
    client.sendCliMessage($(%*{"command": "cliCheck", "root": root}))
    sleep(100)
    doAssert posix.kill(Pid(process.processID()), SIGTERM) == 0
    doAssert process.waitForExit(5000) == 0
    let probe = newSocket()
    defer:
      probe.close()
    var refused = false
    try:
      probe.connect("127.0.0.1", Port(parseInt(port)))
    except OSError:
      refused = true
    doAssert refused
