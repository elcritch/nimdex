## JSON-RPC stdio server for Nimdex.

import std/syncio

import sigils
import sigils/rpcs/jsonrpc
import sigils/rpcs/json/jrAgents
import sigils/rpcs/json/jrStdio as jrStdio

import ../nimdex

type GreetParams = tuple[name: string]

let greetSelector = selector[GreetParams, string]("greet")

proc greetImpl(self: DynamicAgent, args: GreetParams): string =
  discard self
  greet(args.name)

proc newNimdexJsonRpcAdapter*(): JsonRpcAdapter =
  ## Create the JSON-RPC adapter and register Nimdex's public operations.
  let service = DynamicAgent()
  discard service.addMethod(greetSelector, toDynamicMethod(greetImpl))

  result = newJsonRpcAdapter()
  result.registerSelector("nimdex", service, greetSelector)

proc runNimdexJsonRpcStdio*(input: File = stdin, output: File = stdout) =
  ## Serve framed JSON-RPC requests from `input` until EOF.
  ##
  ## The wire format is the LSP Content-Length framing provided by Sigils.
  ## Diagnostics should be written to stderr because `output` is reserved for
  ## JSON-RPC messages.
  startLocalThreadDefault()
  let
    home = getCurrentSigilThread()
    adapter = newNimdexJsonRpcAdapter()
    dispatcher = newJsonRpcDispatcher(adapter)
    io = jrStdio.newJsonRpcStdioIo(input, output)

  dispatcher.connectJsonRpc(io)
  emit dispatcher.jsonRpcStartRequested()

  while io.pollJsonRpcStdio():
    discard home.pollAll(NonBlocking)
