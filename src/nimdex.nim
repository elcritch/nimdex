## Root module for nimdex.

proc greet*(name: string): string =
  ## Returns a greeting for `name`.
  "hello, " & name

when isMainModule:
  import std/os
  import nimdex/cli

  quit runNimdexCli(commandLineParams())
