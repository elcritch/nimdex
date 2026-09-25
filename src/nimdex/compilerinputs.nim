## Inputs used to validate reuse of a successful compiler head.

import std/[algorithm, os, sets, strutils, tables, times]

import ./documents
import ./semantic
import ./workspace

type InputFingerprints* = Table[string, string]

proc addPath(paths: var HashSet[string], path: string) =
  if path.len > 0 and path notin paths:
    paths.incl(normalizeDocumentPath(path))

proc configurationInputs*(workspace: Workspace, head: string): seq[string] =
  var paths = initHashSet[string]()
  for start in [workspace.rootPath, head.parentDir]:
    var directory = start
    while directory.len > 0:
      paths.addPath(directory / "nim.cfg")
      paths.addPath(directory / "config.nims")
      let parent = directory.parentDir
      if parent == directory:
        break
      directory = parent
  paths.addPath(head.changeFileExt("cfg"))
  paths.addPath(head.changeFileExt("nimcfg"))
  paths.addPath(head.changeFileExt("nim.cfg"))
  paths.addPath(head.changeFileExt("nims"))
  for name in ["nim.cfg", "config.nims"]:
    paths.addPath(getConfigDir() / "nim" / name)
    if workspace.compilerPath.len > 0:
      let prefix = workspace.compilerPath.parentDir.parentDir
      paths.addPath(prefix / "config" / name)
      paths.addPath(prefix / "etc/nim" / name)
    when defined(unix):
      paths.addPath("/etc/nim" / name)
  for path in discoverProjectLayout(workspace.rootPath).packageFiles:
    paths.addPath(path)
  for path in paths:
    result.add(path)
  result.sort()

proc resolvedInputs*(
    workspace: Workspace,
    head: string,
    snapshot: SemanticSnapshot,
    compilerOutput: string,
): seq[string] =
  var paths = initHashSet[string]()
  paths.addPath(head)
  for path in configurationInputs(workspace, head):
    paths.addPath(path)
  for module in snapshot.modules:
    paths.addPath(module.sourcePath)
    for path in module.sourceFiles:
      paths.addPath(path)
    for path in module.includes:
      paths.addPath(path)
  # Nim also loads user/compiler configuration outside the project ancestry.
  for line in compilerOutput.splitLines():
    let marker = line.find("used config file '")
    if marker >= 0:
      let start = marker + "used config file '".len
      let finish = line.find('\'', start)
      if finish > start:
        paths.addPath(line[start ..< finish])
  for path in paths:
    result.add(path)
  result.sort()

proc fingerprintInputs*(
    paths: openArray[string], cache: var InputFingerprints
): uint64 =
  var input = ""
  for path in paths:
    input.add(path & "\0")
    if path notin cache:
      if fileExists(path):
        cache[path] = $stableTextHash(readFile(path))
      else:
        cache[path] = "missing"
    input.add(cache[path])
    input.add('\0')
  stableTextHash(input)

proc fingerprintInputs*(paths: openArray[string]): uint64 =
  var cache: InputFingerprints
  fingerprintInputs(paths, cache)

proc fingerprintInputsLegacy*(
    paths: openArray[string], cache: var InputFingerprints
): uint64 =
  ## Validate manifests written before input fingerprints became content-only.
  var input = ""
  for path in paths:
    input.add(path & "\0")
    if path notin cache:
      if fileExists(path):
        let modified = getLastModificationTime(path)
        cache[path] =
          $stableTextHash(readFile(path)) & ":" & $modified.toUnix & ":" &
          $modified.nanosecond
      else:
        cache[path] = "missing"
    input.add(cache[path])
    input.add('\0')
  stableTextHash(input)

proc sourceInventory*(workspace: Workspace): uint64 =
  ## Only names, not contents. New/deleted local modules can change import
  ## resolution. Dependency contents are tracked through resolved BIF inputs.
  var pending = @[workspace.rootPath]
  var paths: seq[string]
  while pending.len > 0:
    let directory = pending.pop()
    if dirExists(directory):
      for kind, path in walkDir(directory):
        case kind
        of pcDir:
          if path.lastPathPart notin ["deps", "nimcache", "vendor"] and
              not path.lastPathPart.startsWith(".") and
              normalizeDocumentPath(path) != workspace.cacheRoot:
            pending.add(path)
        of pcFile:
          if path.endsWith(".nim") or path.endsWith(".nimble") or path.endsWith(".nims") or
              path.endsWith(".cfg"):
            paths.add(path)
        else:
          discard
  paths.sort()
  stableTextHash(paths.join("\0"))

proc compilerEnvironmentFingerprint*(): uint64 =
  ## Track environment that selects the compiler's configuration and tools.
  ## Session-specific editor and shell variables must not invalidate every head.
  var values = ""
  for key in [
    "HOME", "XDG_CONFIG_HOME", "NIM_CONFIG_DIR", "NIMBLE_DIR", "NIMBLE_HOME", "NIMPATH",
    "NIMFLAGS",
  ]:
    values.add(key & "=" & getEnv(key) & "\0")
  stableTextHash(values)
