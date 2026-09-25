import std/[assertions, json, os, osproc, streams, strutils]

import nimdex/cli
import nimdex/documents
import sigils/rpcs/json/jrFraming

const FixtureRoot = currentSourcePath.parentDir / "fixtures/binny_phase0"

var testDaemonPath: string

proc drainProtocolErrors(stream: Stream) {.thread.} =
  while not stream.atEnd():
    discard stream.readLine()

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
  doAssert run.errors.contains("--frontend must be compile or track")

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
