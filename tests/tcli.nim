import std/[assertions, os, osproc, streams, strutils]

import nimdex/cli

const FixtureRoot = currentSourcePath.parentDir / "fixtures/binny_phase0"

var testDaemonPath: string

proc testDaemon(): string =
  if testDaemonPath.len > 0:
    return testDaemonPath
  let repositoryRoot = currentSourcePath.parentDir.parentDir
  testDaemonPath = getTempDir() / ("nimdex-cli-daemon-" & $getCurrentProcessId())
  let nimCache = getTempDir() / ("nimdex-cli-daemon-cache-" & $getCurrentProcessId())
  let compiler = findExe("nim")
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
  let run = runExternalCli(["debug", FixtureRoot, "--cache-root", cacheRoot])
  doAssert run.status == 0, run.output
  doAssert run.output.contains("\"compiler\"")
  doAssert run.output.contains("\"artifactPaths\"")
  doAssert run.output.contains("\"tokenCount\"")
