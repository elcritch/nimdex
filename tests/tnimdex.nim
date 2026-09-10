import std/unittest

import nimdex

suite "nimdex":
  test "greets by name":
    check greet("Nim") == "hello, Nim"

