## Probe compiler support for the Binny phase-0 semantic-artifact workflow.
##
## Run from the repository root:
##
##   nim r tools/binny_phase0.nim
##   nim r tools/binny_phase0.nim --build
##
## Nimdex requires a compiler that advertises --genBif. The default compiler is
## the project-local development compiler when it is present.

import std/[algorithm, os, osproc, strutils]

import nimdex/binnycompat

type CompilerProbe = object
  compiler: string
  version: string
  help: string
  hasGenBif: bool
  nifler: string
  niflerVersion: string

proc runCommand(arguments: openArray[string]): tuple[output: string, exitCode: int] =
  var command: seq[string]
  for argument in arguments:
    command.add(quoteShell(argument))
  execCmdEx(command.join(" "), options = {poStdErrToStdOut, poUsePath, poEvalCommand})

proc defaultCompiler(repoRoot: string): string =
  let projectCompiler = repoRoot / "deps/nim-devel/bin/nim"
  if fileExists(projectCompiler):
    return projectCompiler
  findExe("nim")

proc probeCompiler(compiler: string): CompilerProbe =
  result.compiler = compiler
  let version = runCommand([compiler, "--version"])
  result.version = version.output.strip()
  let help = runCommand([compiler, "--fullhelp"])
  result.help = help.output
  result.hasGenBif = "--genBif" in result.help

  let compilerPath =
    if fileExists(compiler):
      absolutePath(compiler)
    else:
      findExe(compiler)
  let compilerDir = if compilerPath.len > 0: compilerPath.parentDir else: ""
  let sibling = compilerDir / ("nifler" & ExeExt)
  if sibling.len > 0 and fileExists(sibling):
    result.nifler = sibling
  else:
    result.nifler = findExe("nifler")
  if result.nifler.len > 0:
    result.niflerVersion = runCommand([result.nifler, "--version"]).output.strip()

proc printProbe(probe: CompilerProbe) =
  echo "compiler: ", probe.compiler
  echo "version:"
  echo probe.version
  echo "has --genBif: ", probe.hasGenBif
  echo "nifler: ", if probe.nifler.len > 0: probe.nifler else: "unavailable"
  if probe.niflerVersion.len > 0:
    echo "nifler version: ", probe.niflerVersion

proc inspectArtifacts(cacheDir: string, fixture: string): bool =
  var paths: seq[string]
  for path in walkDirRec(cacheDir):
    if path.endsWith(".s.bif"):
      paths.add(path)
  paths.sort()

  if paths.len == 0:
    echo "artifacts: none"
    return

  var fixtureFound = false
  for path in paths:
    let report = inspectBinnyArtifact(path)
    if report.sourcePath != fixture:
      continue
    fixtureFound = true
    echo "fixture artifact: ", path
    echo "  status: ", report.status
    echo "  source: ", report.sourcePath
    echo "  tags: ", report.tags.join(", ")
    echo "  declarations: ", report.declarations.len
    for declaration in report.declarations:
      echo "    ",
        declaration.visibility, " ", declaration.tag, " ", declaration.name, " @ ",
        declaration.location.line, ":", declaration.location.column
    if report.metadataError.len > 0:
      echo "  metadata error: ", report.metadataError
    if report.failure.message.len > 0:
      echo "  load failure: ", report.failure.message
  if not fixtureFound:
    echo "fixture artifact: none for ", fixture
  result = fixtureFound

proc buildFixture(probe: CompilerProbe, repoRoot: string): bool =
  let fixture = repoRoot / "tests/fixtures/binny_phase0/main.nim"
  let cacheDir = getTempDir() / ("nimdex-binny-phase0-" & $getCurrentProcessId())
  if dirExists(cacheDir):
    removeDir(cacheDir)
  createDir(cacheDir)
  defer:
    if dirExists(cacheDir):
      removeDir(cacheDir)

  let command = [
    probe.compiler,
    "c",
    "--genBif:on",
    "--app:staticlib",
    "--nimcache:" & cacheDir,
    "--out:" & cacheDir / "libphase0",
    fixture,
  ]
  echo "build command:"
  var quotedCommand: seq[string]
  for argument in command:
    quotedCommand.add(quoteShell(argument))
  echo quotedCommand.join(" ")
  let build = runCommand(command)
  echo build.output.strip()
  echo "build exit code: ", build.exitCode
  let fixtureFound = inspectArtifacts(cacheDir, fixture)
  result = build.exitCode == 0 and fixtureFound

proc main() =
  let repoRoot = currentSourcePath.parentDir.parentDir
  let compiler =
    if paramCount() > 0 and not paramStr(1).startsWith("--"):
      paramStr(1)
    else:
      defaultCompiler(repoRoot)
  if compiler.len == 0:
    stderr.writeLine("nimdex requires a Nim compiler with --genBif:on")
    quit(2)

  let probe = probeCompiler(compiler)
  printProbe(probe)

  if "--build" notin commandLineParams():
    if not probe.hasGenBif:
      stderr.writeLine("nimdex requires a Nim compiler with --genBif:on")
      quit(2)
    echo "fixture: ", repoRoot / "tests/fixtures/binny_phase0/main.nim"
    echo "next: nim r tools/binny_phase0.nim --build"
    return

  if not probe.hasGenBif:
    stderr.writeLine("nimdex requires a Nim compiler with --genBif:on")
    quit(2)
  if not buildFixture(probe, repoRoot):
    stderr.writeLine("phase-0 fixture build did not produce a readable BIF")
    quit(1)

when isMainModule:
  main()
