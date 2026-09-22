## Controlled Nim compiler refreshes and owned compiler diagnostics.

import std/[algorithm, atomics, os, osproc, strutils]

import chronicles

import ./bifindex
import ./documents
import ./semantic
import ./workspace

type
  CompilerDiagnosticSeverity* = enum
    cdsError
    cdsWarning
    cdsInformation
    cdsHint

  CompilerDiagnostic* = object ## A copied diagnostic emitted by the compiler.
    sourcePath*: string
    sourceUri*: string
    line*: int32 ## One-based compiler line number.
    column*: int32 ## Zero-based compiler byte column.
    hasLocation*: bool
    severity*: CompilerDiagnosticSeverity
    message*: string

  CompilerCapabilities* = object ## Capability evidence for one compiler binary.
    compilerPath*: string
    version*: string
    revision*: string
    help*: string
    available*: bool
    supportsGenBif*: bool
    fingerprint*: uint64
    error*: string

  CompilerCancellationState* = object
    cancelled: Atomic[bool]

  CompilerCancellation* = ptr CompilerCancellationState

  CompilerRefreshRequest* = object ## One complete, stamped compiler refresh.
    workspace*: Workspace
    capabilities*: CompilerCapabilities
    documentGeneration*: uint64
    cancellation*: CompilerCancellation

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

  CompilerProcessOutput = object
    stdout: string
    stderr: string
    exitCode: int

  CompilerSourceFingerprint = object
    fingerprint: uint64
    paths: seq[string]

proc symbolCount(snapshot: SemanticSnapshot): int =
  for module in snapshot.modules:
    result += module.symbols.len

proc newCompilerCancellation*(): CompilerCancellation =
  result = cast[CompilerCancellation](allocShared0(sizeof(CompilerCancellationState)))
  result[].cancelled.store(false, moRelaxed)

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

proc runExternalCommand(
    executable: string, arguments: openArray[string], workingDir, captureDir: string
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
    command = command,
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
    let shellArguments =
      ["-c", command & " > " & quoteShell(stdoutPath) & " 2> " & quoteShell(stderrPath)]

  var process = startProcess(
    shell, workingDir = workingDir, args = shellArguments, options = {poUsePath}
  )
  result.exitCode = process.waitForExit()
  process.close()
  result.stdout = readIfPresent(stdoutPath)
  result.stderr = readIfPresent(stderrPath)
  debug "Nim command completed",
    compilerPath = executable,
    exitCode = result.exitCode,
    stdoutBytes = result.stdout.len,
    stderrBytes = result.stderr.len

proc compilerRevision(version: string): string =
  for line in version.splitLines:
    let trimmed = line.strip()
    if trimmed.toLowerAscii().startsWith("git hash:"):
      if trimmed.len > "git hash:".len:
        return trimmed["git hash:".len .. ^1].strip()

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
        version = result.version,
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
  result.fingerprint = stableTextHash(fingerprintInput)

proc requireCompiler*(capabilities: CompilerCapabilities): string =
  ## Return an actionable prerequisite error, or an empty string when ready.
  if not capabilities.available:
    return
      if capabilities.error.len > 0:
        capabilities.error
      else:
        "Nimdex requires a usable Nim compiler"
  if not capabilities.supportsGenBif:
    return "Nimdex requires a Nim compiler that supports --genBif:on"

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

proc appendFingerprintPart(target: var string, label, value: string) =
  target.add(label)
  target.add(':')
  target.add($value.len)
  target.add(':')
  target.add(value)
  target.add('\0')

proc sourcePathsForFingerprint(
    workspace: Workspace, entryPoints: openArray[string]
): seq[string] =
  var candidates: seq[string]
  candidates.add(entryPoints)
  if workspace.rootPath.len > 0 and dirExists(workspace.rootPath):
    for path in walkDirRec(workspace.rootPath):
      if path.endsWith(".nim") or path.endsWith(".nims"):
        candidates.add(path)
  for root in workspace.importPaths:
    if not dirExists(root):
      continue
    for path in walkDirRec(root):
      if path.endsWith(".nim") or path.endsWith(".nims"):
        candidates.add(path)

  for path in candidates:
    let normalized = normalizeDocumentPath(path)
    if normalized.len == 0 or normalized in result:
      continue
    if workspace.cacheRoot.len > 0 and
        normalized.startsWith(workspace.cacheRoot & DirSep):
      continue
    if fileExists(normalized):
      result.add(normalized)
  result.sort()

proc sourceFingerprint(
    workspace: Workspace, entryPoints: openArray[string]
): CompilerSourceFingerprint =
  result.paths = sourcePathsForFingerprint(workspace, entryPoints)
  var input = ""
  for path in result.paths:
    appendFingerprintPart(input, "path", path)
    try:
      appendFingerprintPart(input, "text", $stableTextHash(readFile(path)))
    except CatchableError:
      appendFingerprintPart(input, "text", "unreadable")
  result.fingerprint = stableTextHash(input)

proc discoverCompilerEntryPoints*(workspace: Workspace): seq[string] =
  ## Select a conservative default entry point when the client omitted one.
  if workspace.entryPoints.len > 0:
    for path in workspace.entryPoints:
      if path.endsWith(".nim") and path notin result:
        result.add(path)
    return

  if workspace.rootPath.len == 0:
    return
  if workspace.rootPath.endsWith(".nim") and fileExists(workspace.rootPath):
    result.add(workspace.rootPath)
    return

  let mainPath = workspace.rootPath / "main.nim"
  if fileExists(mainPath):
    result.add(normalizeDocumentPath(mainPath))
    return

  let projectName = workspace.rootPath.lastPathPart
  let namedPath = workspace.rootPath / (projectName & ".nim")
  if fileExists(namedPath):
    result.add(normalizeDocumentPath(namedPath))

proc forbiddenCompilerArgument(argument: string): bool =
  let normalized = argument.toLowerAscii()
  normalized in [
    "r", "run", "e", "eval", "--run", "--eval", "--nimcache", "--genbif", "--out",
    "--outdir",
  ] or normalized.startsWith("--nimcache:") or normalized.startsWith("--genbif:") or
    normalized.startsWith("--out:") or normalized.startsWith("--outdir:")

proc compilerArguments(
    request: CompilerRefreshRequest, cachePath, entryPoint: string
): seq[string] =
  result.add("c")
  for argument in request.workspace.nimArguments:
    result.add(argument)
  for importPath in request.workspace.importPaths:
    result.add("--path:" & importPath)
  ## These options are appended after user switches so the refresh command is
  ## always an artifact-only, BIF-producing build in its private cache.
  result.add("--genBif:on")
  result.add("--compileOnly:on")
  result.add("--forceBuild:on")
  result.add("--colors:off")
  result.add("--filenames:abs")
  result.add("--nimcache:" & cachePath)
  result.add("--outdir:" & cachePath)
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

proc runCompilerRefresh*(request: CompilerRefreshRequest): CompilerRefreshResult =
  ## Run and index one complete compiler generation.
  result.compiler = request.capabilities
  if result.compiler.compilerPath.len == 0:
    result.compiler = probeCompiler(request.workspace.compilerPath)
  result.stamp = AnalysisStamp(
    valid: true,
    projectId: request.workspace.projectId,
    documentGeneration: request.documentGeneration,
    configurationGeneration: request.workspace.configurationGeneration,
    configurationFingerprint: request.workspace.configurationFingerprint,
    compilerFingerprint: result.compiler.fingerprint,
  )

  let entryPoints = request.workspace.discoverCompilerEntryPoints()
  info "Preparing compiler-backed analysis",
    projectId = request.workspace.projectId,
    workspaceRoot = request.workspace.rootPath,
    compilerPath = result.compiler.compilerPath,
    entryPoints = entryPoints,
    importPaths = request.workspace.importPaths,
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

  let prerequisite = result.compiler.requireCompiler()
  if prerequisite.len > 0:
    warn "Compiler-backed analysis prerequisite failed", failure = prerequisite
    result.addBuildFailure(prerequisite, entryPoints[0])
    return
  if request.cancellation.isCompilerCancelled():
    result.cancelled = true
    result.error = "compiler refresh was cancelled"
    return

  let sources = sourceFingerprint(request.workspace, entryPoints)
  result.stamp.sourceFingerprint = sources.fingerprint
  let cacheBase =
    if request.workspace.cacheRoot.len > 0:
      request.workspace.cacheRoot
    else:
      getTempDir() / "nimdex" / "nimcache"
  result.cachePath =
    cacheBase / (
      $result.compiler.fingerprint & "-" & $request.workspace.configurationFingerprint &
      "-" & $sources.fingerprint
    )
  info "Using Nimdex compiler cache", cachePath = result.cachePath
  ensureDirectory(result.cachePath)

  var buildFailed = false
  for entryPoint in entryPoints:
    if request.cancellation.isCompilerCancelled():
      result.cancelled = true
      result.error = "compiler refresh was cancelled"
      return
    let arguments = request.compilerArguments(result.cachePath, entryPoint)
    result.commandLines.add(commandLine(result.compiler.compilerPath, arguments))
    info "Compiling Nim entry point",
      compilerPath = result.compiler.compilerPath,
      entryPoint = entryPoint,
      workspaceRoot = request.workspace.rootPath
    let process = runExternalCommand(
      result.compiler.compilerPath, arguments, request.workspace.rootPath,
      result.cachePath,
    )
    result.exitCode = process.exitCode
    result.stdout.add(process.stdout)
    result.stderr.add(process.stderr)
    if process.exitCode != 0:
      buildFailed = true
      warn "Nim compiler failed",
        compilerPath = result.compiler.compilerPath,
        entryPoint = entryPoint,
        exitCode = process.exitCode,
        stderr = process.stderr
      break

  result.diagnostics = collectCompilerDiagnostics(
    result.stdout, result.stderr, request.workspace.rootPath, entryPoints[0]
  )
  if request.cancellation.isCompilerCancelled():
    result.cancelled = true
    result.error = "compiler refresh was cancelled"
    return
  if buildFailed:
    result.addBuildFailure(
      "Nim compiler exited with status " & $result.exitCode, entryPoints[0]
    )
    return

  result.artifactPaths = discoverBifArtifacts(@[result.cachePath])
  info "Discovered compiler-generated BIF artifacts",
    cachePath = result.cachePath,
    artifactCount = result.artifactPaths.len,
    artifactPaths = result.artifactPaths
  if result.artifactPaths.len == 0:
    warn "Nim compiler produced no semantic BIF artifacts",
      compilerPath = result.compiler.compilerPath,
      entryPoints = entryPoints,
      cachePath = result.cachePath
    result.addBuildFailure(
      "Nim compiler produced no semantic BIF artifacts", entryPoints[0]
    )
    return
  result.snapshot = buildBifIndex(request.workspace, @[result.cachePath])
  if result.snapshot.failureCount() > 0:
    for failure in result.snapshot.failures:
      result.diagnostics.add(
        CompilerDiagnostic(
          sourcePath: failure.sourcePath,
          sourceUri: documentUriFromPath(failure.sourcePath),
          severity: cdsError,
          message: failure.message,
        )
      )
    result.error = "one or more generated BIF artifacts could not be indexed"
    return

  result.snapshot.configurationFingerprint = request.workspace.configurationFingerprint
  result.snapshot.compilerFingerprint = result.compiler.fingerprint
  result.snapshot.sourceFingerprint = sources.fingerprint
  result.snapshot.analysisStamp = result.stamp
  result.ok = true
  info "Compiler-backed analysis completed",
    projectId = request.workspace.projectId,
    moduleCount = result.snapshot.moduleCount(),
    symbolCount = result.snapshot.symbolCount(),
    tokenCount = result.snapshot.tokenCount(),
    artifactCount = result.artifactPaths.len
