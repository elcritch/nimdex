import std/[os, strutils, tempfiles, times, unittest]
import nimdex/[compiler, documents, language, semantic, workspace]

const Compiler = currentSourcePath.parentDir.parentDir / "deps/nim-devel/bin/nim"

suite "compiler navigation, effects and overlays":
  test "resolves qualified uses and static effects against current buffer text":
    let root = normalizeDocumentPath(createTempDir("nimdex-navigation-", ""))
    defer:
      removeDir(root)
    let main = root / "main.nim"
    let support = root / "support.nim"
    let mainText =
      """import support
proc pure*(): int {.raises: [].} = 1
proc inferred*() = risky()
proc caught*() =
  try: risky()
  except ValueError, IOError: discard
proc local*(): int =
  let value = 3
  result = value
discard pure()
risky()
include piece
discard included()
"""
    let supportText =
      """proc risky*() {.raises: [ValueError, IOError].} =
  raise newException(ValueError, "oops")
"""
    let piece = root / "piece.nim"
    let pieceText = "proc included*(): int {.raises: [].} = 1\n"
    writeFile(piece, pieceText)
    writeFile(main, mainText)
    writeFile(support, supportText)
    let workspace = initWorkspace(
      documentUriFromPath(root),
      entryPoints = @[main],
      compilerPath = Compiler,
      cacheRoot = root / "cache",
    )
    let capabilities = probeCompiler(Compiler)
    let cold = runCompilerRefresh(
      CompilerRefreshRequest(workspace: workspace, capabilities: capabilities)
    )
    require cold.ok
    setLastModificationTime(
      support, getLastModificationTime(support) + initDuration(seconds = 2)
    )
    let runtime = newLanguageRuntime()
    defer:
      runtime.close()
    runtime.installIndex(cold.snapshot)
    let uri = documentUriFromPath(main)
    discard runtime.request(
      LanguageRequest(
        kind: lrkOpen, uri: uri, version: 1, text: mainText, positionEncoding: peUtf16
      )
    )
    for item in [
      (1, 6, "raises: []"),
      (2, 6, "ValueError"),
      (3, 6, "raises: []"),
      (10, 1, "IOError"),
    ]:
      let hover = runtime.request(
        LanguageRequest(
          kind: lrkHover,
          uri: uri,
          line: item[0],
          character: item[1],
          positionEncoding: peUtf16,
        )
      )
      checkpoint "hover " & $item[0] & ": " & hover.preview
      check hover.ok
      check hover.found
      check item[2] in hover.preview
    let imported = runtime.request(
      LanguageRequest(
        kind: lrkDefinition, uri: uri, line: 10, character: 2, positionEncoding: peUtf16
      )
    )
    require imported.ok and imported.found
    check imported.symbols.len == 1
    check imported.symbols[0].symbol.location.path == support
    check imported.symbols[0].start == TextPosition(line: 0, character: 5)
    let local = runtime.request(
      LanguageRequest(
        kind: lrkDefinition, uri: uri, line: 8, character: 12, positionEncoding: peUtf16
      )
    )
    require local.ok and local.found
    check local.symbols[0].start == TextPosition(line: 7, character: 6)

    let edited = mainText.replace("pure", "clean")
    let dirtySupport = supportText.replace("IOError", "OSError")
    discard runtime.request(
      LanguageRequest(
        kind: lrkChange, uri: uri, version: 2, text: edited, positionEncoding: peUtf16
      )
    )
    discard runtime.request(
      LanguageRequest(
        kind: lrkOpen, uri: documentUriFromPath(support), version: 1, text: dirtySupport
      )
    )
    let stale = runtime.request(
      LanguageRequest(
        kind: lrkDefinition, uri: uri, line: 9, character: 10, positionEncoding: peUtf16
      )
    )
    check not stale.found
    # Include the changed catch clause so the inferred exceptions are valid.
    let dirtyMain = edited.replace("IOError", "OSError").replace("included", "updated")
    let dirtyPiece = pieceText.replace("included", "updated")
    discard runtime.request(
      LanguageRequest(
        kind: lrkOpen, uri: documentUriFromPath(piece), text: dirtyPiece, version: 1
      )
    )
    discard runtime.request(
      LanguageRequest(
        kind: lrkChange,
        uri: uri,
        version: 3,
        text: dirtyMain,
        positionEncoding: peUtf16,
      )
    )
    let dirty = runCompilerRefresh(
      CompilerRefreshRequest(
        workspace: workspace,
        capabilities: capabilities,
        previousHeads: cold.heads,
        overlays:
          @[
            initDocumentSnapshot(uri, dirtyMain, 3),
            initDocumentSnapshot(documentUriFromPath(support), dirtySupport, 1),
            initDocumentSnapshot(documentUriFromPath(piece), dirtyPiece, 1),
          ],
      )
    )
    require dirty.ok
    check dirty.snapshot.sourceFingerprint != cold.snapshot.sourceFingerprint
    check readFile(main) == mainText
    check readFile(support) == supportText
    check readFile(piece) == pieceText
    runtime.installIndex(dirty.snapshot)
    let hover = runtime.request(
      LanguageRequest(
        kind: lrkHover, uri: uri, line: 10, character: 1, positionEncoding: peUtf16
      )
    )
    check hover.found
    check "OSError" in hover.preview
    check "IOError" notin hover.preview
    let definition = runtime.request(
      LanguageRequest(
        kind: lrkDefinition, uri: uri, line: 9, character: 10, positionEncoding: peUtf16
      )
    )
    require definition.found
    check definition.symbols[0].symbol.name == "clean"
    check definition.symbols[0].start == TextPosition(line: 1, character: 5)
    let included = runtime.request(
      LanguageRequest(
        kind: lrkDefinition,
        uri: uri,
        line: 12,
        character: 10,
        positionEncoding: peUtf16,
      )
    )
    require included.found
    check included.symbols[0].symbol.location.path == piece
    check included.symbols[0].symbol.name == "updated"
    discard runtime.request(LanguageRequest(kind: lrkClose, uri: uri))
    let closed = runtime.request(
      LanguageRequest(
        kind: lrkDefinition, uri: uri, line: 9, character: 10, positionEncoding: peUtf16
      )
    )
    check not closed.found

  test "distinguishes overloads, generic calls, shadowed locals and UTF-16 uses":
    let root = normalizeDocumentPath(createTempDir("nimdex-use-kinds-", ""))
    defer:
      removeDir(root)
    let main = root / "main.nim"
    let text =
      """proc label*(value: int): int = value
proc label*(value: string): string = value
proc twice*[T](value: T): T = value + value
let first = label(1)
let second = label("two")
let generic = twice(2)
proc shadow*(): int =
  let value = 7
  block:
    let value = 9
    result = value
  result += value
let café* = 4
discard café
let utfText = "😀"; discard label(3)
proc camelName*() = discard
camel_name()
proc `++`*(left, right: int): int = left + right
discard 1 ++ 2
let specialized = twice[int](3)
"""
    writeFile(main, text)
    let workspace = initWorkspace(
      documentUriFromPath(root),
      entryPoints = @[main],
      compilerPath = Compiler,
      cacheRoot = root / "cache",
    )
    let refresh = runCompilerRefresh(
      CompilerRefreshRequest(
        workspace: workspace, capabilities: probeCompiler(Compiler)
      )
    )
    require refresh.ok
    let runtime = newLanguageRuntime()
    defer:
      runtime.close()
    runtime.installIndex(refresh.snapshot)
    for item in [
      (3, 14, 0, 5),
      (4, 15, 1, 5),
      (5, 15, 2, 5),
      (10, 15, 9, 8),
      (11, 13, 7, 6),
      (13, 9, 12, 4),
      (14, 29, 0, 5),
      (16, 4, 15, 5),
      (18, 10, 17, 5),
      (19, 19, 2, 5),
    ]:
      let response = runtime.request(
        LanguageRequest(
          kind: lrkDefinition,
          uri: documentUriFromPath(main),
          line: item[0],
          character: item[1],
          positionEncoding: peUtf16,
        )
      )
      checkpoint "definition at " & $item
      require response.ok
      check response.found
      if response.found:
        check response.symbols.len == 1
        check response.symbols[0].start ==
          TextPosition(line: item[2], character: item[3])
