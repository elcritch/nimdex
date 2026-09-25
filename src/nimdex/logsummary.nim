## Small, bounded values for structured operational logs.

import std/[os, strutils, unicode]

proc logText*(value: string, maxBytes = 200): string =
  ## Keep user or compiler text on one bounded log line.
  if maxBytes <= 0:
    return
  for character in value.utf8:
    let shown = if character in ["\r", "\n", "\t"]: " " else: character
    if result.len + shown.len > maxBytes:
      result.add("...")
      break
    result.add(shown)

proc logFirstLine*(value: string, maxBytes = 200): string =
  ## Keep a banner's identifying line without its remaining boilerplate.
  if value.len == 0:
    return
  logText(value.splitLines()[0], maxBytes)

proc samplePaths*(paths: openArray[string], maxNames = 4): string =
  ## Show a few basenames, including the last one when the list is truncated.
  if paths.len == 0:
    return "[]"
  let count = max(maxNames, 2)
  var names: seq[string]
  if paths.len <= count:
    for path in paths:
      names.add(logText(path.extractFilename(), 64))
  else:
    for index in 0 ..< count - 1:
      names.add(logText(paths[index].extractFilename(), 64))
    names.add("...")
    names.add(logText(paths[^1].extractFilename(), 64))
  names.join(", ")

proc cacheRunId*(cacheRoot: string, paths: openArray[string]): string =
  ## Identify one per-head cache subtree shared by the supplied BIF paths.
  ## An empty result means the paths span heads or are outside this cache.
  if cacheRoot.len == 0 or paths.len == 0:
    return
  let prefix = cacheRoot & DirSep
  for path in paths:
    if not path.startsWith(prefix):
      return ""
    let parts = path[prefix.len ..^ 1].split(DirSep)
    if parts.len < 2:
      return ""
    let headIndex = if parts[1] == "overlays": 2 else: 1
    if headIndex >= parts.len or parts[headIndex].len == 0:
      return ""
    if result.len == 0:
      result = parts[headIndex]
    elif result != parts[headIndex]:
      return ""
