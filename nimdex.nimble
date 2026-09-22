version       = "0.1.0"
author        = "Your Name"
description   = "A Nim package."
license       = "MIT"
srcDir        = "src"
bin            = @[
  "nimdex"
]

requires "nim >= 2.0.0"

requires "gh:elcritch/binny >= 0.5.22"
requires "gh:elcritch/sigils >= 0.30.0"
requires "chronicles >= 0.12.2"
