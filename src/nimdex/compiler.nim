## Controlled Nim compiler refreshes and owned compiler diagnostics.

import std/[algorithm, atomics, os, osproc, strutils, syncio, tables, times, monotimes]

when defined(posix):
  import std/posix

import chronicles

import ./bifindex
import ./documents
import ./compilerinputs
import ./headcache
import ./incremental
import ./logsummary
import ./semantic
import ./workspace

export
  headcache.HeadAnalysis, headcache.CompilerDiagnostic,
  headcache.CompilerDiagnosticSeverity

type
  CompilerCapabilities* = object ## Capability evidence for one compiler binary.
    compilerPath*: string
    version*: string
    revision*: string
    help*: string
    available*: bool
    supportsGenBif*: bool
    supportsTrack*: bool
    niflerPath*: string
    nifmakePath*: string
    fingerprint*: uint64
    error*: string

  CompilerCancellationState* = object
    cancelled: Atomic[bool]
    priorityHead: Atomic[int] ## Index in the refresh's fixed list of heads.

  CompilerCancellation* = ptr CompilerCancellationState

  CompilerRefreshRequest* = object ## One complete, stamped compiler refresh.
    workspace*: Workspace
    capabilities*: CompilerCapabilities
    documentGeneration*: uint64
    sourceGeneration*: uint64
    cancellation*: CompilerCancellation
    previousHeads*: seq[HeadAnalysis]
    forceRebuild*: bool
    priorityHead*: string
    overlays*: seq[DocumentSnapshot]

  CompilerHeadProgress* = object ## One independently validated head completion.
    stamp*: AnalysisStamp
    headPath*: string
    analysis*: HeadAnalysis
    ok*: bool
    restored*: bool
    reused*: bool
    error*: string
    diagnostics*: seq[CompilerDiagnostic]

  CompilerProgressCallback* = proc(progress: CompilerHeadProgress) {.closure.}

  CompilerRefreshResult* = object ## Owned output of a compiler refresh.
    ok*: bool
    cancelled*: bool
    exitCode*: int
    compiler*: CompilerCapabilities
    stamp*: AnalysisStamp
    cachePath*: string
    commandLines*: seq[string]
    artifactPaths*: seq[string]
    stdout*: string
    stderr*: string
    diagnostics*: seq[CompilerDiagnostic]
    snapshot*: SemanticSnapshot
    error*: string
    heads*: seq[HeadAnalysis]
    compiledHeads*: int
    reusedHeads*: int
    loadedArtifacts*: int
    reusedArtifacts*: int
    restoredHeads*: int
    failedHeads*: seq[string]

  CompilerProcessOutput = object
    stdout: string
    stderr: string
    exitCode: int

proc symbolCount(snapshot: SemanticSnapshot): int =
  for module in snapshot.modules:
    result += module.symbols.len

proc newCompilerCancellation*(): CompilerCancellation =
  result = cast[CompilerCancellation](allocShared0(sizeof(CompilerCancellationState)))
  result[].cancelled.store(false, moRelaxed)
  result[].priorityHead.store(-1, moRelaxed)

proc prioritizeCompilerHead*(cancellation: CompilerCancellation, index: int) =
  ## Reorder pending work without cancelling the head already being checked.
  if not cancellation.isNil:
    cancellation[].priorityHead.store(index, moRelease)

proc cancelCompiler*(cancellation: CompilerCancellation) =
  if not cancellation.isNil:
    cancellation[].cancelled.store(true, moRelease)

proc isCompilerCancelled*(cancellation: CompilerCancellation): bool =
  not cancellation.isNil and cancellation[].cancelled.load(moAcquire)

proc releaseCompilerCancellation*(cancellation: CompilerCancellation) =
  if not cancellation.isNil:
    deallocShared(cancellation)

proc resolveCompilerPath(path: string): string =
  if path.len == 0:
    let projectCompiler =
      currentSourcePath.parentDir.parentDir.parentDir / "deps/nim-devel/bin/nim"
    if fileExists(projectCompiler):
      return normalizeDocumentPath(projectCompiler)
    return findExe("nim")

  if isAbsolute(path) or DirSep in path or AltSep in path:
    if fileExists(path):
      return normalizeDocumentPath(path)
    return
  findExe(path)

proc commandLine(executable: string, arguments: openArray[string]): string =
  result = quoteShell(executable)
  for argument in arguments:
    result.add(' ')
    result.add(quoteShell(argument))

proc ensureDirectory(path: string) =
  if path.len > 0 and not dirExists(path):
    createDir(path)

proc readIfPresent(path: string): string =
  if fileExists(path):
    try:
      return readFile(path)
    except CatchableError:
      discard

const MaxCompilerCaptureBytes = 8 * 1024 * 1024

proc readCompilerCapture(path: string): string =
  if not fileExists(path):
    return
  let file = open(path)
  defer:
    file.close()
  result = newString(int(min(getFileSize(path), MaxCompilerCaptureBytes.int64)))
  if result.len > 0:
    result.setLen(file.readBuffer(addr result[0], result.len))
  if getFileSize(path) > MaxCompilerCaptureBytes:
    result.add("\nError: compiler output exceeded the capture limit\n")

proc terminateCompilerProcess(process: Process) =
  when defined(posix):
    let pid = Pid(process.processID)
    if getpgid(pid) == pid:
      discard posix.kill(-pid, SIGTERM)
      sleep(100)
      discard posix.kill(-pid, SIGKILL)
    else:
      process.kill()
  elif defined(windows):
    discard execCmd("taskkill /PID " & $process.processID & " /T /F")
    if process.peekExitCode() == -1:
      process.kill()
  else:
    process.kill()

proc runExternalCommand(
    executable: string,
    arguments: openArray[string],
    workingDir, captureDir: string,
    cancellation: CompilerCancellation = nil,
    progressHead = "",
): CompilerProcessOutput =
  ## Use a shell only as a redirection wrapper. Every executable, argument, and
  ## capture path is quoted independently, so user configuration is not parsed
  ## as shell syntax.
  ensureDirectory(captureDir)
  let stdoutPath = captureDir / ".nimdex-compiler.stdout"
  let stderrPath = captureDir / ".nimdex-compiler.stderr"
  let command = commandLine(executable, arguments)
  debug "Running Nim command",
    compilerPath = executable,
    workingDirectory = workingDir,
    command = logText(command, 300),
    commandBytes = command.len,
    stdoutPath = stdoutPath,
    stderrPath = stderrPath

  when defined(windows):
    let shell =
      if getEnv("COMSPEC").len > 0:
        getEnv("COMSPEC")
      else:
        "cmd.exe"
    let shellArguments = [
      "/d",
      "/s",
      "/c",
      command & " > " & quoteShell(stdoutPath) & " 2> " & quoteShell(stderrPath),
    ]
  else:
    let shell = "/bin/sh"
    let shellArguments = [
      "-c",
      "exec " & command & " > " & quoteShell(stdoutPath) & " 2> " &
        quoteShell(stderrPath),
    ]

  var process = startProcess(
    shell,
    workingDir = workingDir,
    args = shellArguments,
    options = {poUsePath, poDaemon},
  )
  defer:
    # Even an I/O exception while supervising must not leave a compiler alive.
    if process.peekExitCode() == -1:
      process.terminateCompilerProcess()
      discard process.waitForExit()
    process.close()
  let started = getMonoTime()
  var nextProgressSecond = 5'i64
  var stopped = false
  while process.peekExitCode() == -1:
    let elapsedSeconds = (getMonoTime() - started).inSeconds
    if progressHead.len > 0 and elapsedSeconds >= nextProgressSecond:
      info "Nim compiler still running",
        entryPoint = progressHead,
        elapsedSeconds = elapsedSeconds,
        stdoutBytes = (if fileExists(stdoutPath): getFileSize(stdoutPath)
        else: 0'i64),
        stderrBytes = (if fileExists(stderrPath): getFileSize(stderrPath)
        else: 0'i64)
      nextProgressSecond = elapsedSeconds + 5
    if cancellation.isCompilerCancelled() or elapsedSeconds >= 300 or
        (fileExists(stdoutPath) and getFileSize(stdoutPath) > MaxCompilerCaptureBytes) or
        (fileExists(stderrPath) and getFileSize(stderrPath) > MaxCompilerCaptureBytes):
      stopped = true
      process.terminateCompilerProcess()
      break
    sleep(20)
  result.exitCode = process.waitForExit()
  result.stdout = readCompilerCapture(stdoutPath)
  result.stderr = readCompilerCapture(stderrPath)
  if stopped and not cancellation.isCompilerCancelled() and
      (getMonoTime() - started).inSeconds >= 300:
    result.stderr.add("\nError: compiler exceeded the five-minute analysis limit\n")
  debug "Nim command completed",
    compilerPath = executable,
    exitCode = result.exitCode,
    stdoutBytes = result.stdout.len,
    stderrBytes = result.stderr.len

proc saveHeadCompilerLog(
    cachePath, entryPoint, command: string, output: CompilerProcessOutput
): string =
  result = cachePath / (entryPoint.extractFilename() & "-compile.log")
  var log: File
  if not open(log, result, fmWrite):
    raise newException(IOError, "could not open compiler log: " & result)
  try:
    log.writeLine("Command: " & command)
    log.writeLine("Exit code: " & $output.exitCode)
    if output.stdout.len > 0:
      log.writeLine("\n--- stdout ---")
      log.write(output.stdout)
    if output.stderr.len > 0:
      log.writeLine("\n--- stderr ---")
      log.write(output.stderr)
  finally:
    log.close()
  for name in [".nimdex-compiler.stdout", ".nimdex-compiler.stderr"]:
    let capture = cachePath / name
    if fileExists(capture):
      removeFile(capture)

proc compilerRevision(version: string): string =
  for line in version.splitLines:
    let trimmed = line.strip()
    if trimmed.toLowerAscii().startsWith("git hash:"):
      if trimmed.len > "git hash:".len:
        return trimmed["git hash:".len .. ^1].strip()

proc compilerCompanion(compilerPath, name: string): string =
  let sibling = compilerPath.parentDir / (name & ExeExt)
  if fileExists(sibling):
    return normalizeDocumentPath(sibling)
  findExe(name)

proc probeCompiler*(path = ""): CompilerCapabilities =
  ## Probe the selected executable without assuming a particular Nim release.
  result.compilerPath = resolveCompilerPath(path)
  info "Probing Nim compiler", requestedPath = path, compilerPath = result.compilerPath
  if result.compilerPath.len == 0:
    result.error =
      if path.len > 0:
        "configured Nim compiler was not found: " & path
      else:
        "Nimdex requires a Nim compiler with --genBif:on"
    result.fingerprint = stableTextHash(result.error)
    warn "Nim compiler was not found", requestedPath = path, failure = result.error
    return

  let captureDir = getTempDir() / ("nimdex-compiler-probe-" & $getCurrentProcessId())
  try:
    let versionResult =
      runExternalCommand(result.compilerPath, ["--version"], "", captureDir)
    result.version = (versionResult.stdout & versionResult.stderr).strip()
    let helpResult =
      runExternalCommand(result.compilerPath, ["--fullhelp"], "", captureDir)
    result.help = helpResult.stdout & helpResult.stderr
    result.available = versionResult.exitCode == 0 and helpResult.exitCode == 0
    result.supportsGenBif = result.help.contains("--genBif")
    for line in result.help.splitLines():
      if line.strip().startsWith("track "):
        result.supportsTrack = true
    result.niflerPath = compilerCompanion(result.compilerPath, "nifler")
    result.nifmakePath = compilerCompanion(result.compilerPath, "nifmake")
    result.revision = compilerRevision(result.version)
    if not result.available:
      result.error = "unable to probe Nim compiler: " & result.compilerPath
    elif not result.supportsGenBif:
      result.error =
        "Nimdex requires a Nim compiler that supports --genBif:on: " &
        result.compilerPath
    if result.available and result.supportsGenBif:
      info "Nim compiler is ready",
        compilerPath = result.compilerPath,
        version = logFirstLine(result.version, 80),
        revision = result.revision,
        supportsGenBif = result.supportsGenBif
    else:
      warn "Nim compiler probe failed",
        compilerPath = result.compilerPath,
        available = result.available,
        supportsGenBif = result.supportsGenBif,
        failure = result.error
  except CatchableError as error:
    result.error = "unable to run Nim compiler probe: " & error.msg
    warn "Nim compiler probe raised an exception",
      compilerPath = result.compilerPath, failure = error.msg

  var fingerprintInput =
    result.compilerPath & "\0" & result.version & "\0" & result.revision & "\0" &
    $result.supportsGenBif
  for path in [result.compilerPath, result.niflerPath, result.nifmakePath]:
    fingerprintInput.add("\0" & path)
    if fileExists(path):
      fingerprintInput.add(
        "\0" & $getFileSize(path) & "\0" & $getLastModificationTime(path)
      )
  result.fingerprint = stableTextHash(fingerprintInput)

proc requireCompiler*(
    capabilities: CompilerCapabilities, frontend = cfCompile
): string =
  ## Return an actionable prerequisite error, or an empty string when ready.
  if not capabilities.available:
    return
      if capabilities.error.len > 0:
        capabilities.error
      else:
        "Nimdex requires a usable Nim compiler"
  if not capabilities.supportsGenBif:
    return "Nimdex requires a Nim compiler that supports --genBif:on"
  if frontend in {cfTrack, cfIc}:
    if frontend == cfTrack and not capabilities.supportsTrack:
      return "the selected Nim compiler does not advertise the track frontend"
    if capabilities.niflerPath.len == 0 or capabilities.nifmakePath.len == 0:
      return
        "the " & $frontend &
        " frontend requires nifler and nifmake beside Nim or on PATH"

proc diagnosticSeverityValue(
    label: string
): tuple[known: bool, severity: CompilerDiagnosticSeverity] =
  let normalized = label.toLowerAscii()
  if normalized == "error":
    return (true, cdsError)
  if normalized == "warning":
    return (true, cdsWarning)
  if normalized in ["info", "information"]:
    return (true, cdsInformation)
  if normalized == "hint":
    return (true, cdsHint)

proc diagnosticFromLine(
    line, workingDir, fallbackPath: string
): tuple[known: bool, diagnostic: CompilerDiagnostic] =
  var locationEnd = line.find(')')
  var locationStart = locationEnd - 1
  while locationStart >= 0 and line[locationStart] != '(':
    dec locationStart

  var severity = cdsError
  var message = ""
  var knownSeverity = false
  let suffixStart =
    if locationEnd >= 0:
      locationEnd + 1
    else:
      0
  let suffix =
    if suffixStart < line.len:
      line[suffixStart .. ^1].strip()
    else:
      line
  for label in ["Error:", "Warning:", "Information:", "Info:", "Hint:"]:
    let marker = suffix.find(label)
    if marker < 0:
      continue
    let parsed = diagnosticSeverityValue(label[0 ..< label.len - 1])
    if not parsed.known:
      continue
    knownSeverity = true
    severity = parsed.severity
    let messageStart = marker + label.len
    message =
      if messageStart < suffix.len:
        suffix[messageStart .. ^1].strip()
      else:
        ""
    break

  if not knownSeverity:
    return
  if locationStart < 0 or locationEnd < 0:
    ## Compiler configuration hints are not source diagnostics. Errors without
    ## a location still matter and are attached to the entry point below.
    if severity != cdsError:
      return
    result.diagnostic = CompilerDiagnostic(
      severity: severity,
      message:
        if message.len > 0:
          message
        else:
          line.strip(),
    )
    result.known = true
    return

  let comma = line.find(',', locationStart + 1)
  if comma < 0:
    return
  try:
    let lineNumber = parseInt(line[locationStart + 1 ..< comma].strip())
    let column = parseInt(line[comma + 1 ..< locationEnd].strip())
    var sourcePath = line[0 ..< locationStart].strip()
    if sourcePath.len >= 2 and sourcePath[0] == '"' and sourcePath[^1] == '"':
      sourcePath = sourcePath[1 .. ^2]
    if sourcePath.len > 0 and not isAbsolute(sourcePath):
      sourcePath = workingDir / sourcePath
    result.diagnostic = CompilerDiagnostic(
      sourcePath: normalizeDocumentPath(sourcePath),
      sourceUri: documentUriFromPath(sourcePath),
      line: int32(lineNumber),
      column: int32(column),
      hasLocation: true,
      severity: severity,
      message:
        if message.len > 0:
          message
        else:
          line.strip(),
    )
    result.known = true
  except ValueError:
    discard

proc collectCompilerDiagnostics(
    stdout, stderr, workingDir, fallbackPath: string
): seq[CompilerDiagnostic] =
  for text in [stdout, stderr]:
    for line in text.splitLines:
      let parsed = diagnosticFromLine(line, workingDir, fallbackPath)
      if not parsed.known:
        continue
      var diagnostic = parsed.diagnostic
      if diagnostic.sourcePath.len == 0 and fallbackPath.len > 0:
        diagnostic.sourcePath = normalizeDocumentPath(fallbackPath)
        diagnostic.sourceUri = documentUriFromPath(diagnostic.sourcePath)
      if diagnostic.message.len > 0:
        result.add(diagnostic)

proc discoverCompilerEntryPoints*(
    workspace: Workspace, layout: ProjectLayout
): seq[string] =
  ## Explicit heads override convention-based package and test discovery.
  if workspace.entryPoints.len > 0:
    for path in workspace.entryPoints:
      if path.endsWith(".nim") and path notin result:
        result.add(path)
  else:
    result = layout.heads

proc discoverCompilerEntryPoints*(workspace: Workspace): seq[string] =
  if workspace.entryPoints.len > 0:
    return workspace.discoverCompilerEntryPoints(ProjectLayout())
  workspace.discoverCompilerEntryPoints(discoverProjectLayout(workspace.rootPath))

proc forbiddenCompilerArgument(argument: string): bool =
  let normalized = argument.toLowerAscii()
  normalized in [
    "r", "run", "e", "eval", "--run", "--eval", "--nimcache", "--genbif", "--out",
    "--outdir", "--trackdirty",
  ] or normalized.startsWith("--nimcache:") or normalized.startsWith("--genbif:") or
    normalized.startsWith("--out:") or normalized.startsWith("--outdir:") or
    normalized.startsWith("--trackdirty:") or normalized.startsWith("--trackdirty=")

proc compilerArguments(
    request: CompilerRefreshRequest, cachePath, entryPoint: string
): seq[string] =
  # This compiler's `check --genBif:on` drops semantic statements in SemPass.
  # `track` runs IC's frontend only; `ic` also generates C for its backend.
  let incremental =
    request.workspace.compilerFrontend in {cfTrack, cfIc} and request.overlays.len == 0
  result.add(
    if incremental:
      $request.workspace.compilerFrontend
    else:
      "c"
  )
  for argument in request.workspace.nimArguments:
    result.add(argument)
  for importPath in request.workspace.importPaths:
    result.add("--path:" & importPath)
  ## These options are appended after user switches so the refresh command is
  ## always an artifact-only, BIF-producing build in its private cache.
  result.add("--genBif:on")
  if not incremental or request.workspace.compilerFrontend == cfIc:
    result.add("--compileOnly:on")
  result.add("--colors:off")
  result.add("--filenames:abs")
  result.add("--nimcache:" & cachePath)
  result.add("--outdir:" & cachePath)
  for overlay in request.overlays:
    if ',' in overlay.path or ',' in cachePath:
      raise newException(
        ValueError, "Nim --trackDirty cannot represent paths containing commas"
      )
    let dirtyPath = cachePath / ("buffer-" & $stableTextHash(overlay.path) & ".nim")
    writeFile(dirtyPath, overlay.content)
    result.add("--trackDirty:" & dirtyPath & "," & overlay.path & ",1,0")
  result.add(entryPoint)

proc addBuildFailure(result: var CompilerRefreshResult, message, fallbackPath: string) =
  result.error = message
  result.diagnostics.add(
    CompilerDiagnostic(
      sourcePath: normalizeDocumentPath(fallbackPath),
      sourceUri: documentUriFromPath(fallbackPath),
      severity: cdsError,
      message: message,
    )
  )

type HeadBuild = object
  analysis: HeadAnalysis
  diagnostics: seq[CompilerDiagnostic]
  error, command, stdout, stderr: string
  exitCode: int

proc buildHead(
    request: CompilerRefreshRequest,
    entryPoint, cachePath: string,
    reuseKey: uint64,
    artifactCache: var BifReuseCache,
): HeadBuild =
  result.analysis =
    HeadAnalysis(headPath: entryPoint, cachePath: cachePath, reuseKey: reuseKey)
  ensureDirectory(cachePath)
  forgetHead(cachePath)
  let incremental =
    request.workspace.compilerFrontend in {cfTrack, cfIc} and request.overlays.len == 0
  # The IC driver owns and may reset this directory. Keep manifests and process
  # captures outside it, and retain its outputs for per-module rebuild decisions.
  let compilerCache =
    if incremental:
      cachePath / "frontend"
    else:
      cachePath
  var configPaths = configurationInputs(request.workspace, entryPoint)
  if incremental:
    let contextPath = cachePath / "frontend-context"
    var reset = request.forceRebuild
    if fileExists(compilerCache / "ic_config.cfg.nif"):
      try:
        for path in incrementalConfigurationInputs(compilerCache):
          if path notin configPaths:
            configPaths.add(path)
      except CatchableError:
        reset = true
    configPaths.sort()
    let frontendKey = $reuseKey & ":" & $fingerprintInputs(configPaths)
    # Filename inventory/environment changes can alter import resolution or
    # static evaluation without changing the compiler's timestamp inputs. Also
    # invalidate precompiled config when a previously absent config is created.
    if reset or readIfPresent(contextPath) != frontendKey:
      if dirExists(compilerCache):
        removeDir(compilerCache)
    writeFile(contextPath, frontendKey)
  else:
    for path in discoverBifArtifacts(@[compilerCache]):
      removeFile(path)
  let beforePaths = configPaths & @[entryPoint]
  let beforeFingerprint = fingerprintInputs(beforePaths)
  let arguments = request.compilerArguments(compilerCache, entryPoint)
  result.command = commandLine(request.capabilities.compilerPath, arguments)
  let compileStarted = getTime()
  info "Compiling Nim head",
    workingDir = request.workspace.rootPath,
    entryPoint = entryPoint,
    cacheRunId = cachePath.extractFilename()
  let process = runExternalCommand(
    request.capabilities.compilerPath, arguments, request.workspace.rootPath, cachePath,
    request.cancellation, entryPoint,
  )
  try:
    let compileLog = saveHeadCompilerLog(cachePath, entryPoint, result.command, process)
    info "Nim compiler output captured",
      entryPoint = entryPoint,
      cacheRunId = cachePath.extractFilename(),
      compileLog = compileLog,
      stdoutBytes = process.stdout.len,
      stderrBytes = process.stderr.len,
      exitCode = process.exitCode
  except CatchableError as error:
    warn "Unable to save Nim compiler log",
      entryPoint = entryPoint,
      stdoutPath = cachePath / ".nimdex-compiler.stdout",
      stderrPath = cachePath / ".nimdex-compiler.stderr",
      failure = error.msg
  result.exitCode = process.exitCode
  result.stdout = process.stdout
  result.stderr = process.stderr
  result.diagnostics = collectCompilerDiagnostics(
    process.stdout, process.stderr, request.workspace.rootPath, entryPoint
  )
  if process.exitCode != 0:
    result.error = "Nim compiler exited with status " & $process.exitCode
    return
  if request.cancellation.isCompilerCancelled():
    return
  result.analysis.artifactPaths =
    if incremental:
      incrementalArtifacts(compilerCache, entryPoint)
    else:
      discoverBifArtifacts(@[compilerCache])
  if result.analysis.artifactPaths.len == 0:
    result.error = "Nim compiler produced no semantic BIF artifacts"
    return
  var snapshot =
    buildBifIndexCached(request.workspace, artifactCache, result.analysis.artifactPaths)
  if snapshot.failureCount() > 0:
    result.error = "one or more generated BIF artifacts could not be indexed"
    return
  if not snapshot.containsModule(entryPoint):
    result.error = "compiler artifacts do not contain the requested head"
    return
  var overlayHashes: Table[string, uint64]
  for overlay in request.overlays:
    overlayHashes[overlay.path] = overlay.textHash
  for module in snapshot.modules.mitems:
    if module.sourcePath in overlayHashes:
      module.sourceTextHash = overlayHashes[module.sourcePath]
    var hasOverlay = false
    for symbol in module.symbols:
      if symbol.location.path in overlayHashes:
        hasOverlay = true
        break
    if hasOverlay:
      var symbols = module.symbols
      for symbol in symbols.mitems:
        if symbol.location.path in overlayHashes:
          symbol.location.sourceTextHash = overlayHashes[symbol.location.path]
      module.setSymbols(move(symbols))
  snapshot.recordHead(entryPoint)
  result.analysis.inputPaths = resolvedInputs(
    request.workspace, entryPoint, snapshot, process.stdout & process.stderr
  )
  if incremental:
    for path in incrementalConfigurationInputs(compilerCache):
      if path notin result.analysis.inputPaths:
        result.analysis.inputPaths.add(path)
      if path notin configPaths:
        configPaths.add(path)
    result.analysis.inputPaths.sort()
    configPaths.sort()
  result.analysis.inputFingerprint = fingerprintInputs(result.analysis.inputPaths)
  var sourceTimes: Table[string, int64]
  for path in result.analysis.inputPaths:
    if fileExists(path):
      let modified = getLastModificationTime(path)
      sourceTimes[path] = int64(modified.toUnixFloat() * 1_000_000_000.0)
      if modified > compileStarted:
        result.error = "compiler inputs changed during analysis; retry refresh"
        return
  if fingerprintInputs(beforePaths) != beforeFingerprint:
    result.error = "compiler inputs changed during analysis; retry refresh"
    return
  if incremental:
    writeFile(
      cachePath / "frontend-context", $reuseKey & ":" & $fingerprintInputs(configPaths)
    )
    # Successful incremental checks can retain byte-identical BIFs with older
    # mtimes than their source (for example after a comment-only edit). Stamp
    # owned locations with the validated build time; never touch compiler files.
    let validatedTime = int64(compileStarted.toUnixFloat() * 1_000_000_000.0)
    for module in snapshot.modules.mitems:
      if sourceTimes.getOrDefault(module.sourcePath) > module.artifactModifiedUnix:
        module.artifactModifiedUnix = validatedTime
      var changed = false
      for symbol in module.symbols:
        if sourceTimes.getOrDefault(symbol.location.path) >
            symbol.location.artifactModifiedUnix:
          changed = true
          break
      if changed:
        var symbols = module.symbols
        for symbol in symbols.mitems:
          if sourceTimes.getOrDefault(symbol.location.path) >
              symbol.location.artifactModifiedUnix:
            symbol.location.artifactModifiedUnix = validatedTime
        module.setSymbols(move(symbols))
  snapshot.compactHead()
  new(result.analysis.snapshot)
  result.analysis.snapshot[] = move(snapshot)
  result.analysis.diagnostics = result.diagnostics

proc headSourceFingerprint*(heads: openArray[HeadAnalysis]): uint64 =
  var fingerprints: seq[string]
  for head in heads:
    fingerprints.add(
      head.headPath & "\0" & $head.inputFingerprint & "\0" & $head.overlayFingerprint
    )
  fingerprints.sort()
  stableTextHash(fingerprints.join("\0"))

proc combinedHeadSnapshot*(
    workspace: Workspace,
    heads: openArray[HeadAnalysis],
    stamp: AnalysisStamp,
    actualHeads: seq[string],
): SemanticSnapshot =
  ## Combine only independently validated heads; unsuccessful contexts stay absent.
  result = initSemanticSnapshot(
    workspace.projectId, workspace.configurationGeneration,
    workspace.configurationFingerprint,
  )
  for head in heads:
    result.mergeHead(head.snapshot[])
  result.sourceFingerprint = headSourceFingerprint(heads)
  result.compilerFingerprint = stamp.compilerFingerprint
  result.analysisStamp = stamp
  result.analysisStamp.sourceFingerprint = result.sourceFingerprint
  # Discovery defines heads even when a context has not been analyzed yet.
  result.graph.heads = actualHeads

proc runCompilerRefresh*(
    request: CompilerRefreshRequest, onHead: CompilerProgressCallback = nil
): CompilerRefreshResult =
  ## Report validated heads progressively and isolate failures to their contexts.
  result.compiler = request.capabilities
  if result.compiler.compilerPath.len == 0:
    result.compiler = probeCompiler(request.workspace.compilerPath)
  result.stamp = AnalysisStamp(
    valid: true,
    projectId: request.workspace.projectId,
    documentGeneration: request.documentGeneration,
    sourceGeneration: request.sourceGeneration,
    configurationGeneration: request.workspace.configurationGeneration,
    configurationFingerprint: request.workspace.configurationFingerprint,
    compilerFingerprint: result.compiler.fingerprint,
  )

  let entryPoints = request.workspace.discoverCompilerEntryPoints()
  info "Preparing compiler-backed analysis",
    workingDir = request.workspace.rootPath,
    compilerPath = result.compiler.compilerPath,
    heads = samplePaths(entryPoints),
    headCount = entryPoints.len,
    importPaths = samplePaths(request.workspace.importPaths),
    importPathCount = request.workspace.importPaths.len,
    cacheRoot = request.workspace.cacheRoot,
    nimArgumentCount = request.workspace.nimArguments.len
  if entryPoints.len == 0:
    warn "No Nim entry point found", workspaceRoot = request.workspace.rootPath
    result.addBuildFailure(
      "no Nim entry point was configured or discovered for the workspace",
      request.workspace.rootPath,
    )
    return
  for argument in request.workspace.nimArguments:
    if argument.forbiddenCompilerArgument():
      warn "Rejected unsupported Nim compiler argument", argument = argument
      result.addBuildFailure(
        "unsupported compiler argument for controlled refresh: " & argument,
        entryPoints[0],
      )
      return

  let prerequisite = result.compiler.requireCompiler(request.workspace.compilerFrontend)
  if prerequisite.len > 0:
    warn "Compiler-backed analysis prerequisite failed", failure = prerequisite
    result.addBuildFailure(prerequisite, entryPoints[0])
    return
  if request.cancellation.isCompilerCancelled():
    result.cancelled = true
    result.error = "compiler refresh was cancelled"
    return

  var effectiveRequest = request
  effectiveRequest.capabilities = result.compiler
  effectiveRequest.workspace.compilerPath = result.compiler.compilerPath
  if request.workspace.automaticImportPaths:
    effectiveRequest.workspace.importPaths =
      discoverProjectLayout(request.workspace.rootPath).sourceDirs
  let cacheBase =
    if request.workspace.cacheRoot.len > 0:
      request.workspace.cacheRoot
    else:
      getTempDir() / "nimdex" / "nimcache"
  result.cachePath =
    cacheBase /
    ($result.compiler.fingerprint & "-" & $request.workspace.configurationFingerprint)
  ensureDirectory(result.cachePath)
  let inventory = sourceInventory(request.workspace)
  let reuseKey = stableTextHash(
    $result.compiler.fingerprint & "\0" & $request.workspace.configurationFingerprint &
      "\0" & $inventory & "\0" & $compilerEnvironmentFingerprint() & "\0" &
      $request.workspace.compilerFrontend & "-bif-v" & $HeadCacheVersion
  )
  var overlayKeys: seq[string]
  for overlay in request.overlays:
    overlayKeys.add(overlay.path & "\0" & $overlay.textHash)
  overlayKeys.sort()
  let overlayFingerprint =
    if overlayKeys.len == 0:
      0'u64
    else:
      stableTextHash(overlayKeys.join("\0"))
  var artifactCache: BifReuseCache
  var inputCache: InputFingerprints
  var diskCache = initHeadCache(result.cachePath)
  for previous in request.previousHeads:
    if not previous.snapshot.isNil:
      artifactCache.rememberModules(previous.snapshot[])
  var pending: seq[int]
  for index in 0 ..< entryPoints.len:
    pending.add(index)
  if request.priorityHead in entryPoints:
    request.cancellation.prioritizeCompilerHead(entryPoints.find(request.priorityHead))

  while pending.len > 0:
    if request.cancellation.isCompilerCancelled():
      result.cancelled = true
      result.error = "compiler refresh was cancelled"
      return
    var selected = 0
    let priority =
      if not request.cancellation.isNil:
        request.cancellation[].priorityHead.load(moAcquire)
      else:
        entryPoints.find(request.priorityHead)
    if priority in pending:
      selected = pending.find(priority)
    let entryPoint = entryPoints[pending[selected]]
    pending.delete(selected)
    let cachePath =
      if request.overlays.len == 0:
        result.cachePath / $stableTextHash(entryPoint)
      else:
        result.cachePath / "overlays" / $stableTextHash(entryPoint)
    var progress = CompilerHeadProgress(stamp: result.stamp, headPath: entryPoint)
    try:
      for previous in request.previousHeads:
        if not request.forceRebuild and previous.headPath == entryPoint and
            not previous.snapshot.isNil and previous.reuseKey == reuseKey and
            previous.overlayFingerprint == overlayFingerprint and
            fingerprintInputs(previous.inputPaths, inputCache) ==
            previous.inputFingerprint:
          progress.analysis = previous
          progress.reused = true
          break
      if not progress.reused and not request.forceRebuild and request.overlays.len == 0:
        progress.restored = diskCache.restoreHead(
          effectiveRequest.workspace, entryPoint, cachePath, reuseKey, inputCache,
          progress.analysis,
        )
      if progress.reused or progress.restored:
        inc result.reusedHeads
        if progress.restored:
          inc result.restoredHeads
          artifactCache.rememberModules(progress.analysis.snapshot[])
        progress.diagnostics = progress.analysis.diagnostics
      else:
        inc result.compiledHeads
        let built =
          buildHead(effectiveRequest, entryPoint, cachePath, reuseKey, artifactCache)
        if built.command.len > 0:
          result.commandLines.add(built.command)
        result.stdout.add(built.stdout)
        result.stderr.add(built.stderr)
        if built.exitCode != 0:
          result.exitCode = built.exitCode
        progress.analysis = built.analysis
        progress.analysis.overlayFingerprint = overlayFingerprint
        progress.error = built.error
        progress.diagnostics = built.diagnostics
      if request.cancellation.isCompilerCancelled():
        result.cancelled = true
        result.error = "compiler refresh was cancelled"
        return
      progress.ok = progress.error.len == 0 and not progress.analysis.snapshot.isNil
      if progress.ok and
          fingerprintInputs(progress.analysis.inputPaths) !=
          progress.analysis.inputFingerprint:
        progress.ok = false
        progress.error = "compiler inputs changed during analysis; retry refresh"
    except CatchableError as error:
      progress.ok = false
      progress.error = error.msg
    if progress.ok:
      result.heads.add(progress.analysis)
      result.artifactPaths.add(progress.analysis.artifactPaths)
    else:
      if progress.error.len == 0:
        progress.error = "head analysis is unavailable"
      result.failedHeads.add(entryPoint)
      result.error = progress.error
      progress.diagnostics.add(
        CompilerDiagnostic(
          sourcePath: entryPoint,
          sourceUri: documentUriFromPath(entryPoint),
          severity: cdsError,
          message: progress.error,
        )
      )
    result.diagnostics.add(progress.diagnostics)
    info "Nim compiler progress",
      entryPoint = entryPoint,
      completedHeads = entryPoints.len - pending.len,
      totalHeads = entryPoints.len,
      status = (
        if not progress.ok:
          "failed"
        elif progress.restored:
          "restored"
        elif progress.reused:
          "reused"
        else:
          "compiled"
      )
    if not onHead.isNil:
      onHead(progress)
    if progress.ok and not progress.reused and not progress.restored and
        request.overlays.len == 0:
      try:
        diskCache.storeHead(progress.analysis)
      except CatchableError as error:
        warn "Unable to save semantic cache", head = entryPoint, failure = error.msg

  # Revalidate before the final snapshot: another head may have read changing inputs.
  var validated: seq[HeadAnalysis]
  var verificationCache: InputFingerprints
  let inventoryCurrent = sourceInventory(request.workspace) == inventory
  for analysis in result.heads:
    if inventoryCurrent and
        fingerprintInputs(analysis.inputPaths, verificationCache) ==
        analysis.inputFingerprint:
      validated.add(analysis)
    else:
      result.failedHeads.add(analysis.headPath)
      result.addBuildFailure(
        "compiler inputs changed during analysis; retry refresh", analysis.headPath
      )
  result.heads = move(validated)
  if request.cancellation.isCompilerCancelled():
    result.cancelled = true
    result.error = "compiler refresh was cancelled"
    return
  result.loadedArtifacts = artifactCache.loadedArtifacts
  result.reusedArtifacts = artifactCache.reusedArtifacts
  result.snapshot =
    combinedHeadSnapshot(request.workspace, result.heads, result.stamp, entryPoints)
  result.stamp = result.snapshot.analysisStamp
  result.ok = result.failedHeads.len == 0
  info "Compiler-backed analysis completed",
    projectId = request.workspace.projectId,
    cacheContextId = result.cachePath.extractFilename(),
    moduleCount = result.snapshot.moduleCount(),
    symbolCount = result.snapshot.symbolCount(),
    compiledHeads = result.compiledHeads,
    reusedHeads = result.reusedHeads,
    restoredHeads = result.restoredHeads,
    failedHeads = samplePaths(result.failedHeads),
    failedHeadCount = result.failedHeads.len,
    loadedArtifacts = result.loadedArtifacts,
    reusedArtifacts = result.reusedArtifacts
