version       = "0.1.0"
author        = "Your Name"
description   = "A Nim package."
license       = "MIT"
srcDir        = "src"
bin            = @[
  "nimdex"
]

requires "nim >= 2.0.0"

requires "gh:elcritch/binny#d21498d11ad5938b5e1371da07e64c91e7bb54d6"
# Scheduler teardown is verified against this Sigils ownership contract.
requires "gh:elcritch/sigils#8d7f00edae632ffe8be88cd2d3dfac6c4d651559"
requires "chronicles >= 0.12.2"
