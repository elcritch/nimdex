## Conservative discovery of conventional Nim packages without running Nimble tasks.

import std/[algorithm, json, os, strutils]

import ./documents

type ProjectLayout* = object
  packageFiles*: seq[string]
  sourceDirs*: seq[string]
  heads*: seq[string]
  warnings*: seq[string]

proc addPath(paths: var seq[string], path: string) =
  let normalized = normalizeDocumentPath(path)
  if normalized notin paths:
    paths.add(normalized)

proc literalValue(text: string): string =
  ## Strip comments outside strings. JSON's string/list grammar covers the
  ## conventional Nimble assignments; computed expressions are rejected.
  var quoted = false
  var escaped = false
  for c in text:
    if c == '#' and not quoted:
      break
    result.add(c)
    if c == '"' and not escaped:
      quoted = not quoted
    if c == '\\' and not escaped:
      escaped = true
    else:
      escaped = false
  result = result.strip()

proc packageMetadata(
    path: string
): tuple[sourceDir: string, bins, warnings: seq[string]] =
  var binText = ""
  var readingBins = false
  for line in readFile(path).splitLines():
    let text = literalValue(line)
    if readingBins:
      binText.add(text)
      readingBins = not text.endsWith("]")
    elif line.len > 0 and line[0] in {' ', '\t'}:
      let equals = text.find('=')
      if equals > 0 and text[0 ..< equals].strip() in ["srcDir", "bin"]:
        result.warnings.add(
          path & ": configure entryPoints/importPaths for conditional metadata"
        )
    elif line.len > 0 and line[0] notin {' ', '\t', '#'}:
      let equals = text.find('=')
      if equals > 0:
        let name = text[0 ..< equals].strip()
        let value = text[equals + 1 .. ^1].strip()
        if name == "srcDir":
          try:
            let parsed = parseJson(value)
            if parsed.kind != JString:
              raise newException(ValueError, "expected string")
            result.sourceDir = parsed.getStr()
          except ValueError:
            result.warnings.add(
              path & ": configure importPaths/entryPoints for dynamic srcDir"
            )
        elif name == "bin":
          binText =
            if value.startsWith("@["):
              value[1 .. ^1]
            else:
              value
          readingBins = binText.startsWith("[") and not binText.endsWith("]")
  if binText.len > 0:
    try:
      # Trailing commas are conventional in multiline Nim lists.
      let parsed = parseJson(binText.replace(",]", "]"))
      if parsed.kind != JArray:
        raise newException(ValueError, "expected list")
      for item in parsed:
        if item.kind != JString:
          raise newException(ValueError, "expected binary name")
        result.bins.add(item.getStr())
    except ValueError:
      result.bins.setLen(0)
      result.warnings.add(path & ": configure entryPoints for dynamic bin metadata")

proc addHead(layout: var ProjectLayout, path: string) =
  if fileExists(path) and path.endsWith(".nim"):
    layout.heads.addPath(path)

proc discoverProjectLayout*(root: string): ProjectLayout =
  ## Each test is an independent compiler head, even if another head imports it.
  if root.endsWith(".nim") and fileExists(root):
    result.addHead(root)
  elif dirExists(root):
    for kind, path in walkDir(root):
      if kind == pcFile and path.endsWith(".nimble"):
        result.packageFiles.addPath(path)
    result.packageFiles.sort()
    for package in result.packageFiles:
      let metadata = packageMetadata(package)
      let sourceDir = normalizeDocumentPath(root / metadata.sourceDir)
      result.sourceDirs.addPath(sourceDir)
      result.warnings.add(metadata.warnings)
      result.addHead(sourceDir / (package.splitFile().name & ".nim"))
      result.addHead(sourceDir / "main.nim")
      for binary in metadata.bins:
        result.addHead(sourceDir / binary.addFileExt("nim"))
    if result.packageFiles.len == 0:
      let sourceDir =
        if dirExists(root / "src"):
          root / "src"
        else:
          root
      result.sourceDirs.addPath(sourceDir)
      result.addHead(sourceDir / (root.lastPathPart & ".nim"))
      result.addHead(sourceDir / "main.nim")
    result.addHead(root / "main.nim")
    result.addHead(root / (root.lastPathPart & ".nim"))
    if dirExists(root / "tests"):
      for path in walkFiles(root / "tests" / "t*.nim"):
        result.addHead(path)
  result.heads.sort()
  result.sourceDirs.sort()
