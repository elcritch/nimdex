import std/[os, strutils]

--mm:atomicArc
--threads:on
switch("define", "chronicles_default_output_device=stderr")

task test, "run unit tests":
  for testFile in listFiles("tests/"):
    if testFile.endsWith(".nim") and testFile.splitFile().name.startsWith("t"):
      exec("nim c -r " & quoteShell(testFile))
