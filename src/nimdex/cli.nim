## A small LSP/JSON-RPC client and daemon entry point for Nimdex.

import std/[json, net, os, options, osproc, streams, strutils, syncio, typedthreads]

import chronicles
import sigils/rpcs/json/jrFraming

import ./cliipc
import ./clicapture
import ./documents
import ./logsummary
import ./lsp
import ./projectlayout
import ./workspace

const NimdexVersion = "0.1.0"

type
  CliCommand = enum
    cliCheck
    cliSymbols
    cliDebug
    cliDaemon
    cliStop
    cliHelp
    cliVersion

  CliOptions = object
    command: CliCommand
    projectPath: string
    compilerPath: string
    compilerFrontend: string
    cacheRoot: string
    entryPoints: seq[string]
    importPaths: seq[string]
    artifactRoots: seq[string]
    nimArguments: seq[string]
    query: string
    debug: bool
    listenPort: int
    connectPort: int

  CliParseResult = object
    options: CliOptions
    error: string

  RpcSession = ref object
    process: Process
    input: Stream
    output: Stream
    errorOutput: Stream
    errorDrainState: RpcErrorDrain
    errorDrainThread: Thread[ptr RpcErrorDrain]
    parser: JsonRpcFrameParser
    diagnosticLog: RollingLog
    diagnosticCount: int
    diagnosticCaptureFailed: bool

  RpcErrorDrain = object
    stream: Stream
    logPath: string
    totalBytes: int
    rotations: int
    failure: string

  RpcReadResult = object
    found: bool
    frame: JsonNode
    error: string

  RpcCallResult = object
    response: JsonNode
    error: string

proc writeUsage(output: File) =
  output.writeLine("Usage: nimdex <command> [project] [options]")
  output.writeLine("")
  output.writeLine("Commands:")
  output.writeLine("  daemon      Run the LSP/JSON-RPC daemon on stdin/stdout")
  output.writeLine("  check       Ask a daemon for a project analysis summary")
  output.writeLine("  symbols     List project symbols through the daemon")
  output.writeLine("  debug       Print daemon/compiler/BIF diagnostics")
  output.writeLine("  stop        Shut down a listening daemon")
  output.writeLine("  help        Show this help")
  output.writeLine("  version     Show the Nimdex version")
  output.writeLine("")
  output.writeLine("Project defaults to the current directory.")
  output.writeLine("")
  output.writeLine("Options:")
  output.writeLine("  --project PATH       Project directory")
  output.writeLine("  --compiler PATH      Nim compiler or executable name")
  output.writeLine("  --frontend MODE      compile (default) or track (incremental)")
  output.writeLine("  --cache-root PATH    Nimdex compiler cache directory")
  output.writeLine("  --entry-point PATH   Nim entry point; may be repeated")
  output.writeLine("  --import-path PATH   Nim import path; may be repeated")
  output.writeLine("  --artifact-root PATH Existing BIF root; may be repeated")
  output.writeLine(
    "  --nim-arg ARG        Extra controlled Nim argument; may be repeated"
  )
  output.writeLine("  --query TEXT         Filter symbols by name")
  output.writeLine("  --debug              Include the detailed daemon report")
  output.writeLine(
    "  --listen PORT        Serve CLI requests on 127.0.0.1 (daemon only)"
  )
  output.writeLine(
    "  --connect PORT       Query a listening daemon instead of starting one"
  )
  output.writeLine("  -h, --help           Show this help")

proc optionValue(
    args: openArray[string], index: var int, option: string
): tuple[value: string, error: string] =
  if index + 1 >= args.len:
    result.error = option & " requires a value"
    return
  inc index
  result.value = args[index]

proc addOptionValue(
    target: var seq[string], args: openArray[string], index: var int, option: string
): string =
  let parsed = optionValue(args, index, option)
  if parsed.error.len > 0:
    return parsed.error
  target.add(parsed.value)

proc parseCli(args: openArray[string]): CliParseResult =
  result.options.command = cliCheck
  result.options.listenPort = -1
  result.options.connectPort = -1
  var commandSeen = false
  var positional: seq[string]
  var index = 0

  while index < args.len:
    let argument = args[index]
    if argument == "--" and index == 0:
      inc index
      continue
    if argument == "--":
      inc index
      while index < args.len:
        positional.add(args[index])
        inc index
      break

    if not commandSeen:
      case argument
      of "check":
        result.options.command = cliCheck
        commandSeen = true
        inc index
        continue
      of "symbols":
        result.options.command = cliSymbols
        commandSeen = true
        inc index
        continue
      of "debug":
        result.options.command = cliDebug
        commandSeen = true
        inc index
        continue
      of "daemon", "start", "serve":
        result.options.command = cliDaemon
        commandSeen = true
        inc index
        continue
      of "stop":
        result.options.command = cliStop
        commandSeen = true
        inc index
        continue
      of "help":
        result.options.command = cliHelp
        commandSeen = true
        inc index
        continue
      of "version":
        result.options.command = cliVersion
        commandSeen = true
        inc index
        continue
      else:
        discard

    case argument
    of "-h", "--help":
      result.options.command = cliHelp
      commandSeen = true
    of "--version":
      result.options.command = cliVersion
      commandSeen = true
    of "--debug":
      result.options.debug = true
    of "--listen", "--connect":
      let parsed = optionValue(args, index, argument)
      if parsed.error.len > 0:
        result.error = parsed.error
        return
      try:
        let port = parseInt(parsed.value)
        if port < 0 or port > 65535 or (argument == "--connect" and port == 0):
          result.error = argument & " requires a valid port (1 to 65535)"
          return
        if argument == "--listen":
          result.options.listenPort = port
        else:
          result.options.connectPort = port
      except ValueError:
        result.error = argument & " requires a numeric port"
        return
    of "-p", "--project":
      let parsed = optionValue(args, index, argument)
      if parsed.error.len > 0:
        result.error = parsed.error
        return
      result.options.projectPath = parsed.value
    of "--compiler", "--compiler-path":
      let parsed = optionValue(args, index, argument)
      if parsed.error.len > 0:
        result.error = parsed.error
        return
      result.options.compilerPath = parsed.value
    of "--cache-root":
      let parsed = optionValue(args, index, argument)
      if parsed.error.len > 0:
        result.error = parsed.error
        return
      result.options.cacheRoot = parsed.value
    of "--frontend":
      let parsed = optionValue(args, index, argument)
      if parsed.error.len > 0:
        result.error = parsed.error
        return
      if parsed.value notin ["compile", "track"]:
        result.error = "--frontend must be compile or track"
        return
      result.options.compilerFrontend = parsed.value
    of "--entry-point":
      result.error = addOptionValue(result.options.entryPoints, args, index, argument)
      if result.error.len > 0:
        return
    of "--import-path":
      result.error = addOptionValue(result.options.importPaths, args, index, argument)
      if result.error.len > 0:
        return
    of "--artifact-root":
      result.error = addOptionValue(result.options.artifactRoots, args, index, argument)
      if result.error.len > 0:
        return
    of "--nim-arg":
      result.error = addOptionValue(result.options.nimArguments, args, index, argument)
      if result.error.len > 0:
        return
    of "--query":
      let parsed = optionValue(args, index, argument)
      if parsed.error.len > 0:
        result.error = parsed.error
        return
      result.options.query = parsed.value
    else:
      if argument.startsWith("-"):
        result.error = "unknown option: " & argument
        return
      positional.add(argument)
    inc index

  if result.options.command in {cliHelp, cliVersion}:
    if positional.len > 0:
      result.error = "unexpected argument: " & positional[0]
    return

  if result.options.listenPort >= 0 and result.options.command != cliDaemon:
    result.error = "--listen requires daemon"
    return
  if result.options.connectPort >= 0 and result.options.command == cliDaemon:
    result.error = "--connect is for CLI queries or stop"
    return
  if result.options.command == cliStop and result.options.connectPort < 0:
    result.error = "stop requires --connect PORT"
    return
  if result.options.connectPort >= 0 and (
    result.options.compilerPath.len > 0 or result.options.compilerFrontend.len > 0 or
    result.options.cacheRoot.len > 0 or result.options.entryPoints.len > 0 or
    result.options.importPaths.len > 0 or result.options.artifactRoots.len > 0 or
    result.options.nimArguments.len > 0
  ):
    result.error = "set analysis options when starting the listening daemon"
    return

  if positional.len > 0:
    result.options.projectPath = positional[0]
  if positional.len > 1:
    if result.options.command == cliSymbols and result.options.query.len == 0:
      result.options.query = positional[1]
    else:
      result.error = "unexpected argument: " & positional[1]
  if positional.len > 2:
    result.error = "unexpected argument: " & positional[2]

proc projectRoot(options: CliOptions): tuple[path: string, error: string] =
  let requested =
    if options.projectPath.len > 0:
      options.projectPath
    else:
      getCurrentDir()
  result.path = normalizeDocumentPath(requested)
  if result.path.len == 0 or not dirExists(result.path):
    result.error = "project directory does not exist: " & requested

proc jsonStringArray(values: openArray[string]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc rpcRequest(id: int, methodName: string, params: JsonNode): string

proc initializeMessage(options: CliOptions, root: string): string =
  var capabilities = newJObject()
  var general = newJObject()
  general["positionEncodings"] = jsonStringArray(["utf-8", "utf-16"])
  capabilities["general"] = general

  var initializationOptions = newJObject()
  initializationOptions["autoCompile"] = %true
  if options.compilerFrontend.len > 0:
    initializationOptions["compilerFrontend"] = %options.compilerFrontend
  if options.compilerPath.len > 0:
    initializationOptions["compilerPath"] = %options.compilerPath
  if options.cacheRoot.len > 0:
    initializationOptions["cacheRoot"] = %options.cacheRoot
  if options.entryPoints.len > 0:
    initializationOptions["entryPoints"] = jsonStringArray(options.entryPoints)
  if options.importPaths.len > 0:
    initializationOptions["importPaths"] = jsonStringArray(options.importPaths)
  if options.artifactRoots.len > 0:
    initializationOptions["artifactRoots"] = jsonStringArray(options.artifactRoots)
    initializationOptions["autoCompile"] = %false
  if options.nimArguments.len > 0:
    initializationOptions["nimArguments"] = jsonStringArray(options.nimArguments)

  var params = newJObject()
  params["rootUri"] = %documentUriFromPath(root)
  params["capabilities"] = capabilities
  params["initializationOptions"] = initializationOptions
  rpcRequest(1, "initialize", params)

proc rpcRequest(id: int, methodName: string, params: JsonNode): string =
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["id"] = %id
  message["method"] = %methodName
  message["params"] = params
  $message

proc rpcNotification(methodName: string, params: JsonNode): string =
  var message = newJObject()
  message["jsonrpc"] = %"2.0"
  message["method"] = %methodName
  message["params"] = params
  $message

proc send(session: RpcSession, payload: string) =
  session.input.write(frameJsonRpcMessage(payload))
  session.input.flush()

proc readFrame(session: RpcSession): RpcReadResult =
  while true:
    let next = session.parser.nextFrame()
    if next.isSome:
      try:
        result.found = true
        result.frame = parseJson(next.get())
        return
      except CatchableError as error:
        result.error = "invalid JSON-RPC response: " & error.msg
        return

    ## The stream's bulk read path may wait for its requested buffer size on
    ## some process-pipe implementations. Read one byte through the stdio
    ## character path, just like the LSP framing reader, so short responses
    ## are visible immediately.
    let character = session.output.readChar()
    if character == '\0':
      result.error = "Nimdex daemon closed its output before responding"
      return
    session.parser.add($character)

proc isResponseFor(frame: JsonNode, id: int): bool =
  frame.kind == JObject and frame.hasKey("id") and frame["id"].kind == JInt and
    frame["id"].getInt() == id

proc reportNotification(session: RpcSession, frame: JsonNode) =
  if frame.kind != JObject or not frame.hasKey("method") or
      frame["method"].kind != JString:
    return
  if frame["method"].getStr() != "textDocument/publishDiagnostics":
    return
  if not frame.hasKey("params") or frame["params"].kind != JObject:
    return
  let params = frame["params"]
  let uri =
    if params.hasKey("uri"):
      params["uri"].getStr()
    else:
      "<document>"
  if not params.hasKey("diagnostics") or params["diagnostics"].kind != JArray:
    return
  for diagnostic in params["diagnostics"]:
    let message =
      if diagnostic.kind == JObject and diagnostic.hasKey("message"):
        diagnostic["message"].getStr()
      else:
        $diagnostic
    if not session.diagnosticCaptureFailed:
      try:
        session.diagnosticLog.write("nimdex: " & uri & ": " & message & "\n")
        inc session.diagnosticCount
        if session.diagnosticCount == 1:
          info "Compiler diagnostics captured", path = session.diagnosticLog.path
      except CatchableError as error:
        session.diagnosticCaptureFailed = true
        warn "Unable to capture compiler diagnostics",
          path = session.diagnosticLog.path, failure = error.msg

proc readResponse(session: RpcSession, id: int, diagnosticOutput: File): RpcCallResult =
  discard diagnosticOutput
  while true:
    let read = session.readFrame()
    if read.error.len > 0:
      result.error = read.error
      return
    if not read.found:
      result.error = "Nimdex daemon did not return a response"
      return
    if read.frame.kind == JObject and read.frame.hasKey("method"):
      session.reportNotification(read.frame)
    if read.frame.isResponseFor(id):
      result.response = read.frame
      return

proc drainRpcErrors(state: ptr RpcErrorDrain) {.thread.} =
  var buffer = newString(4096)
  var capture: RollingLog
  try:
    capture = initRollingLog(state.logPath)
    while true:
      let bytesRead = state.stream.readData(addr buffer[0], buffer.len)
      if bytesRead <= 0:
        break
      capture.write(buffer[0 ..< bytesRead])
  except CatchableError as error:
    state.failure = error.msg
    # Keep draining if capture fails so the child cannot block on a full pipe.
    while state.stream.readData(addr buffer[0], buffer.len) > 0:
      discard
  finally:
    state.totalBytes = capture.totalBytes
    state.rotations = capture.rotations
    capture.close()

proc newRpcSession(root, daemonPath: string): RpcSession =
  debug "Starting Nimdex daemon for CLI request",
    projectRoot = root, daemonPath = daemonPath, workingDirectory = root
  result = RpcSession(
    process: startProcess(
      if daemonPath.len > 0:
        daemonPath
      else:
        getAppFilename(),
      workingDir = root,
      args = ["daemon"],
      options = {poUsePath, poInteractive},
    ),
    parser: initJsonRpcFrameParser(DefaultNimdexMessageSize),
  )
  result.input = result.process.inputStream()
  result.output = result.process.outputStream()
  result.errorOutput = result.process.errorStream()
  let logPrefix =
    getTempDir() /
    ("nimdex-cli-" & $getCurrentProcessId() & "-" & $result.process.processID())
  try:
    result.diagnosticLog = initRollingLog(logPrefix & ".diagnostics.log")
    result.errorDrainState =
      RpcErrorDrain(stream: result.errorOutput, logPath: logPrefix & ".daemon.log")
    createThread(result.errorDrainThread, drainRpcErrors, addr result.errorDrainState)
  except CatchableError:
    result.diagnosticLog.close()
    result.process.kill()
    discard result.process.waitForExit()
    result.process.close()
    raise
  info "Nimdex daemon output captured", path = result.errorDrainState.logPath

proc stopRpcSession(session: RpcSession, diagnosticOutput: File) =
  discard diagnosticOutput
  if session.isNil or session.process.isNil:
    return
  if session.process.running():
    try:
      session.send(rpcNotification("exit", newJObject()))
    except CatchableError:
      discard
  discard session.process.waitForExit()
  joinThread(session.errorDrainThread)
  session.diagnosticLog.close()
  info "Nimdex daemon output captured",
    path = session.errorDrainState.logPath,
    bytes = session.errorDrainState.totalBytes,
    rotations = session.errorDrainState.rotations
  if session.diagnosticCount > 0:
    info "Compiler diagnostics captured",
      path = session.diagnosticLog.path,
      count = session.diagnosticCount,
      bytes = session.diagnosticLog.totalBytes,
      rotations = session.diagnosticLog.rotations
  if session.errorDrainState.failure.len > 0:
    warn "Unable to capture Nimdex daemon output",
      path = session.errorDrainState.logPath, failure = session.errorDrainState.failure
  session.process.close()

proc responseError(response: JsonNode): string =
  if response.kind != JObject or not response.hasKey("error"):
    return
  let error = response["error"]
  if error.kind == JObject and error.hasKey("message"):
    return error["message"].getStr()
  $error

proc initializeSession(
    session: RpcSession, options: CliOptions, root: string, diagnosticOutput: File
): string =
  session.send(initializeMessage(options, root))
  let initialized = session.readResponse(1, diagnosticOutput)
  if initialized.error.len > 0:
    return initialized.error
  let initializeError = responseError(initialized.response)
  if initializeError.len > 0:
    return "initialize failed: " & initializeError
  session.send(rpcNotification("initialized", newJObject()))

proc requestOnSession(
    session: RpcSession,
    options: CliOptions,
    methodName: string,
    params: JsonNode,
    diagnosticOutput: File,
): tuple[response: JsonNode, debug: JsonNode, error: string] =
  const requestId = 2
  try:
    if options.command in {cliCheck, cliDebug}:
      # Project-wide commands need the final outcome of every discovered head.
      # Document queries in an editor can already use completed heads.
      while true:
        session.send(rpcRequest(requestId, LspDebugMethod, %*{"summaryOnly": true}))
        let status = session.readResponse(requestId, diagnosticOutput)
        if status.error.len > 0:
          result.error = status.error
          return
        let statusError = responseError(status.response)
        if statusError.len > 0:
          result.error = statusError
          return
        let report = status.response["result"]
        if not report["semantic"]["loading"].getBool():
          if report["refresh"]["error"].getStr().len > 0:
            result.error = report["refresh"]["error"].getStr()
            return
          break
        sleep(50)
    session.send(rpcRequest(requestId, methodName, params))
    let requested = session.readResponse(requestId, diagnosticOutput)
    if requested.error.len > 0:
      result.error = requested.error
      return
    result.response = requested.response
    let requestError = responseError(result.response)
    if requestError.len > 0:
      result.error = requestError
      return

    let shouldDebug = options.command in {cliCheck, cliDebug} or options.debug
    if shouldDebug and methodName != LspDebugMethod:
      session.send(rpcRequest(requestId + 1, LspDebugMethod, newJObject()))
      let debugResponse = session.readResponse(requestId + 1, diagnosticOutput)
      if debugResponse.error.len > 0:
        result.error = debugResponse.error
        return
      let debugError = responseError(debugResponse.response)
      if debugError.len > 0:
        result.error = debugError
        return
      result.debug = debugResponse.response["result"]
  except CatchableError as error:
    result.error = error.msg

proc shutdownSession(session: RpcSession, diagnosticOutput: File) =
  if session.isNil or session.process.isNil or not session.process.running():
    return
  try:
    session.send(rpcRequest(4, "shutdown", newJObject()))
    discard session.readResponse(4, diagnosticOutput)
  except CatchableError:
    discard

proc runDaemonRequest(
    options: CliOptions,
    root: string,
    methodName: string,
    params: JsonNode,
    diagnosticOutput: File,
    daemonPath: string,
): tuple[response: JsonNode, debug: JsonNode, error: string] =
  var session: RpcSession
  try:
    session = newRpcSession(root, daemonPath)
    result.error = session.initializeSession(options, root, diagnosticOutput)
    if result.error.len == 0:
      result = session.requestOnSession(options, methodName, params, diagnosticOutput)
  except CatchableError as error:
    result.error = error.msg
  finally:
    session.shutdownSession(diagnosticOutput)
    session.stopRpcSession(diagnosticOutput)

proc printSymbols(response: JsonNode, output: File): int =
  if response.kind != JObject or not response.hasKey("result") or
      response["result"].kind != JArray:
    output.writeLine("no symbols found")
    return 0
  let values = response["result"]
  for symbol in values:
    if symbol.kind != JObject:
      continue
    let name =
      if symbol.hasKey("name"):
        symbol["name"].getStr()
      else:
        "<symbol>"
    var location = "<unknown>"
    if symbol.hasKey("location") and symbol["location"].kind == JObject:
      let source = symbol["location"]
      if source.hasKey("uri"):
        location = pathFromDocumentUri(source["uri"].getStr())
        if location.len == 0:
          location = source["uri"].getStr()
      if source.hasKey("range") and source["range"].kind == JObject:
        let start = source["range"]["start"]
        if start.kind == JObject:
          location.add(
            ":" & $(start["line"].getInt() + 1) & ":" &
              $(start["character"].getInt() + 1)
          )
    output.writeLine(location & " " & name)
  if values.len == 0:
    output.writeLine("no symbols found")
  0

proc printSummary(debug: JsonNode, output: File): int =
  if debug.kind != JObject:
    output.writeLine("Nimdex returned no debug report")
    return 1
  let workspace = debug["workspace"]
  let compiler = debug["compiler"]
  let semantic = debug["semantic"]
  output.writeLine("project: " & workspace["rootPath"].getStr())
  output.writeLine("compiler: " & compiler["path"].getStr())
  output.writeLine("modules: " & $semantic["moduleCount"].getInt())
  output.writeLine("symbols: " & $semantic["symbolCount"].getInt())
  output.writeLine("BIF tokens: " & $semantic["tokenCount"].getInt())
  0

proc projectEntryPoint(options: CliOptions, root: string): string =
  for configured in options.entryPoints:
    let candidate =
      if isAbsolute(configured):
        configured
      else:
        root / configured
    if fileExists(candidate):
      return normalizeDocumentPath(candidate)

  let layout = discoverProjectLayout(root)
  if layout.heads.len > 0:
    return layout.heads[0]

proc projectRequest(
    options: CliOptions, root: string
): tuple[methodName: string, params: JsonNode] =
  result.params = newJObject()
  if options.command in {cliCheck, cliDebug}:
    result.params["textDocument"] =
      %*{"uri": documentUriFromPath(options.projectEntryPoint(root))}
    result.methodName = "textDocument/documentSymbol"
  else:
    result.params["query"] = %options.query
    result.methodName = "workspace/symbol"

proc callListeningDaemon(port: int, request: JsonNode): JsonNode =
  let socket = newSocket()
  try:
    socket.connect("127.0.0.1", Port(port))
    socket.sendCliMessage($request)
    result = parseJson(socket.receiveCliMessage())
  finally:
    socket.close()

proc runConnectedRequest(
    options: CliOptions, root: string
): tuple[response: JsonNode, debug: JsonNode, error: string] =
  try:
    let request =
      %*{
        "command": $options.command,
        "root": root,
        "query": options.query,
        "debug": options.debug,
      }
    let reply = callListeningDaemon(options.connectPort, request)
    if reply.kind != JObject:
      result.error = "listening daemon returned an invalid response"
    elif reply.hasKey("error") and reply["error"].kind == JString:
      result.error = reply["error"].getStr()
    else:
      result.response = reply["response"]
      result.debug = reply["debug"]
  except CatchableError as error:
    result.error =
      "could not query 127.0.0.1:" & $options.connectPort & ": " & error.msg

proc serviceReply(
    session: RpcSession,
    serverOptions: CliOptions,
    root: string,
    request: JsonNode,
    diagnosticOutput: File,
): JsonNode =
  if request.kind != JObject:
    return %*{"error": "invalid CLI request"}
  let command = request{"command"}.getStr("")
  if command notin ["cliCheck", "cliSymbols", "cliDebug"]:
    return %*{"error": "unknown CLI command: " & command}
  if request{"root"}.getStr("") != root:
    return %*{"error": "daemon serves " & root & "; specify that project"}
  var options = serverOptions
  case command
  of "cliCheck":
    options.command = cliCheck
  of "cliSymbols":
    options.command = cliSymbols
  of "cliDebug":
    options.command = cliDebug
  else:
    discard
  options.query = request{"query"}.getStr("")
  options.debug = request{"debug"}.getBool(false)
  let projectRequest = options.projectRequest(root)
  let reply = session.requestOnSession(
    options, projectRequest.methodName, projectRequest.params, diagnosticOutput
  )
  if reply.error.len > 0:
    return %*{"error": reply.error}
  result = newJObject()
  result["response"] =
    if reply.response.isNil:
      newJNull()
    else:
      reply.response
  result["debug"] =
    if reply.debug.isNil:
      newJNull()
    else:
      reply.debug

proc runCliService(options: CliOptions, errorOutput: File, daemonPath: string): int =
  let project = options.projectRoot()
  if project.error.len > 0:
    errorOutput.writeLine("nimdex: " & project.error)
    return 2
  let listener = newSocket()
  var session: RpcSession
  try:
    listener.bindAddr(Port(options.listenPort), "127.0.0.1")
    listener.listen()
    session = newRpcSession(project.path, daemonPath)
    let initError = session.initializeSession(options, project.path, errorOutput)
    if initError.len > 0:
      errorOutput.writeLine("nimdex: " & initError)
      return 1
    info "Nimdex CLI listener ready",
      address = "127.0.0.1:" & $listener.getLocalAddr()[1], workingDir = project.path
    while true:
      var client: Socket
      listener.accept(client)
      var stopping = false
      try:
        let request = parseJson(client.receiveCliMessage(timeoutMs = 5000))
        if request.kind == JObject and request{"command"}.getStr("") == "stop":
          client.sendCliMessage($(%*{"stopping": true}))
          stopping = true
        else:
          if not session.process.running():
            session.stopRpcSession(errorOutput)
            session = newRpcSession(project.path, daemonPath)
            let initError =
              session.initializeSession(options, project.path, errorOutput)
            if initError.len > 0:
              raise newException(IOError, initError)
          let reply = session.serviceReply(options, project.path, request, errorOutput)
          client.sendCliMessage($reply)
      except CatchableError as error:
        try:
          client.sendCliMessage($(%*{"error": error.msg}))
        except CatchableError:
          discard
      finally:
        client.close()
      if stopping:
        break
  except CatchableError as error:
    errorOutput.writeLine("nimdex: " & error.msg)
    return 1
  finally:
    listener.close()
    session.shutdownSession(errorOutput)
    session.stopRpcSession(errorOutput)
  0

proc runProjectCommand(
    options: CliOptions, output, errorOutput: File, daemonPath: string
): int =
  let root = options.projectRoot()
  if root.error.len > 0:
    errorOutput.writeLine("nimdex: " & root.error)
    return 2

  info "Running Nimdex CLI command",
    command = $options.command,
    workingDir = root.path,
    compilerPath = options.compilerPath,
    cacheRoot = options.cacheRoot,
    configuredHeads = samplePaths(options.entryPoints),
    configuredHeadCount = options.entryPoints.len,
    importPaths = samplePaths(options.importPaths),
    importPathCount = options.importPaths.len,
    bifs = samplePaths(options.artifactRoots),
    bifRootCount = options.artifactRoots.len,
    query = logText(options.query, 80)

  let projectQuery = options.projectRequest(root.path)
  let reply =
    if options.connectPort >= 0:
      runConnectedRequest(options, root.path)
    else:
      runDaemonRequest(
        options, root.path, projectQuery.methodName, projectQuery.params, errorOutput,
        daemonPath,
      )
  if reply.error.len > 0:
    errorOutput.writeLine("nimdex: " & reply.error)
    return 1

  if options.command == cliSymbols:
    result = printSymbols(reply.response, output)
    if options.debug:
      if reply.debug.kind == JObject:
        errorOutput.writeLine(reply.debug.pretty())
      else:
        errorOutput.writeLine("nimdex: daemon returned no debug report")
  elif options.command == cliCheck:
    if reply.debug.isNil or reply.debug.kind != JObject:
      return 1
    let semantic = reply.debug["semantic"]
    if not semantic["ready"].getBool():
      errorOutput.writeLine("nimdex: semantic snapshot is not ready")
      return 1
    result = printSummary(reply.debug, output)
  else:
    if not reply.debug.isNil and reply.debug.kind == JObject:
      output.writeLine(reply.debug.pretty())
    elif reply.response.kind == JObject and reply.response.hasKey("result"):
      output.writeLine(reply.response["result"].pretty())
    else:
      output.writeLine(reply.response.pretty())

proc runStopCommand(options: CliOptions, output, errorOutput: File): int =
  try:
    let reply = callListeningDaemon(options.connectPort, %*{"command": "stop"})
    if reply.kind != JObject or not reply.hasKey("stopping") or
        not reply["stopping"].getBool():
      errorOutput.writeLine("nimdex: listening daemon did not acknowledge stop")
      return 1
    output.writeLine("nimdex daemon stopped")
  except CatchableError as error:
    errorOutput.writeLine(
      "nimdex: could not stop 127.0.0.1:" & $options.connectPort & ": " & error.msg
    )
    return 1
  0

proc runNimdexCli*(
    args: openArray[string],
    output: File = stdout,
    errorOutput: File = stderr,
    input: File = stdin,
    daemonPath = "",
): int =
  ## Run the CLI. Project commands talk to a child `daemon` via LSP framing.
  ## `daemonPath` is useful to embedding callers and tests; the executable
  ## itself defaults to launching its own `daemon` subcommand.
  let parsed = parseCli(args)
  if parsed.error.len > 0:
    errorOutput.writeLine("nimdex: " & parsed.error)
    writeUsage(errorOutput)
    return 2

  case parsed.options.command
  of cliHelp:
    writeUsage(output)
    0
  of cliVersion:
    output.writeLine("nimdex " & NimdexVersion)
    0
  of cliDaemon:
    if parsed.options.listenPort >= 0:
      runCliService(parsed.options, errorOutput, daemonPath)
    else:
      runNimdexLspStdio(
        input,
        output,
        compilerPath = parsed.options.compilerPath,
        compilerFrontend =
          if parsed.options.compilerFrontend == "track": cfTrack else: cfCompile,
      )
  of cliStop:
    runStopCommand(parsed.options, output, errorOutput)
  of cliCheck, cliSymbols, cliDebug:
    runProjectCommand(parsed.options, output, errorOutput, daemonPath)
