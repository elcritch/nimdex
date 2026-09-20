## Workspace identity and compiler/artifact configuration values.

import std/[os, strutils]

import ./documents

type Workspace* = object
  rootUri*: string
  rootPath*: string
  projectId*: string
  entryPoints*: seq[string]
  importPaths*: seq[string]
  nimArguments*: seq[string]
  artifactRoots*: seq[string]
  configurationGeneration*: uint64
  configurationFingerprint*: uint64

proc normalizedPaths(paths: openArray[string]): seq[string] =
  for path in paths:
    let normalized = normalizeDocumentPath(path)
    if normalized.len > 0 and normalized notin result:
      result.add(normalized)

proc appendConfigPart(target: var string, label, value: string) =
  target.add(label)
  target.add(':')
  target.add($value.len)
  target.add(':')
  target.add(value)
  target.add('\0')

proc initWorkspace*(
    rootUri: string,
    entryPoints: seq[string] = @[],
    importPaths: seq[string] = @[],
    nimArguments: seq[string] = @[],
    artifactRoots: seq[string] = @[],
    configurationGeneration: uint64 = 0,
): Workspace =
  result.rootUri = normalizeDocumentUri(rootUri)
  if result.rootUri.len == 0:
    result.rootUri = rootUri
  result.rootPath = pathFromDocumentUri(result.rootUri)
  result.projectId = if result.rootPath.len > 0: result.rootPath else: result.rootUri
  result.entryPoints = normalizedPaths(entryPoints)
  result.importPaths = normalizedPaths(importPaths)
  result.nimArguments = nimArguments
  result.artifactRoots = normalizedPaths(artifactRoots)
  result.configurationGeneration = configurationGeneration

  var fingerprintInput = ""
  appendConfigPart(fingerprintInput, "root", result.projectId)
  for path in result.entryPoints:
    appendConfigPart(fingerprintInput, "entry", path)
  for path in result.importPaths:
    appendConfigPart(fingerprintInput, "import", path)
  for argument in result.nimArguments:
    appendConfigPart(fingerprintInput, "arg", argument)
  for path in result.artifactRoots:
    appendConfigPart(fingerprintInput, "artifact", path)
  appendConfigPart(fingerprintInput, "generation", $result.configurationGeneration)
  result.configurationFingerprint = stableTextHash(fingerprintInput)

proc containsPath*(workspace: Workspace, path: string): bool =
  ## Return whether a normalized source path belongs to the workspace root.
  let root = workspace.rootPath
  let candidate = normalizeDocumentPath(path)
  if root.len == 0 or candidate.len == 0:
    return false
  if candidate == root:
    return true
  when defined(windows):
    let rootPrefix = root.toLowerAscii() & DirSep
    candidate.toLowerAscii().startsWith(rootPrefix)
  else:
    candidate.startsWith(root & DirSep)
