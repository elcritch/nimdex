import std/[assertions, os, strutils, unittest]

import nimdex/documents
import nimdex/workspace

suite "Nimdex document and workspace values":
  test "keeps compiler and client paths identical through symlinked ancestors":
    when not defined(windows):
      let root =
        normalizeDocumentPath(getTempDir() / ("nimdex-paths-" & $getCurrentProcessId()))
      createDir(root / "real")
      defer:
        removeDir(root)
      createSymlink(root / "real", root / "alias")
      let absent = normalizeDocumentPath(root / "alias/new.nim")
      check absent == root / "real/new.nim"
      writeFile(root / "real/new.nim", "discard\n")
      check normalizeDocumentPath(root / "alias/new.nim") == absent
      check documentUriFromPath(root / "alias/new.nim") == documentUriFromPath(absent)
  test "normalizes file URIs and paths":
    let path =
      normalizeDocumentPath(getTempDir() / "nimdex phase 1" / "source file.nim")
    let uri = documentUriFromPath(path)
    doAssert uri.startsWith("file://")
    doAssert "%20" in uri
    doAssert pathFromDocumentUri(uri) == path
    doAssert normalizeDocumentUri(uri) == uri
    doAssert pathFromDocumentUri("untitled:nimdex") == ""
    doAssert normalizeDocumentUri("untitled:nimdex") == "untitled:nimdex"

  test "builds line indexes for LF and CRLF content":
    let document =
      initDocumentSnapshot("file:///tmp/phase1-lines.nim", "zero\r\none\n", 4)
    doAssert document.lineCount() == 3
    doAssert document.lineText(0) == "zero"
    doAssert document.lineText(1) == "one"
    doAssert document.lineText(2) == ""
    doAssert document.lineStartOffset(1) == 6
    doAssert document.lineEndOffset(0) == 4
    doAssert document.lineEndOffset(1) == 9

  test "maps UTF-16 positions without splitting surrogate pairs":
    let content = "zero\r\ncafé 😀\n"
    let document =
      initDocumentSnapshot("file:///tmp/phase1-unicode.nim", content, 5, peUtf16)
    let lineStart = document.lineStartOffset(1)
    doAssert document.offsetAt(TextPosition(line: 1, character: 4)) == lineStart + 5
    doAssert document.offsetAt(TextPosition(line: 1, character: 5)) == lineStart + 6
    var invalidPosition = 0
    doAssert not document.tryOffsetAt(
      TextPosition(line: 1, character: 6), invalidPosition
    )
    doAssert document.offsetAt(TextPosition(line: 1, character: 7)) ==
      document.lineEndOffset(1)

    let position = document.positionAt(document.lineEndOffset(1))
    doAssert position.line == 1
    doAssert position.character == 7
    doAssert document.positionAt(content.len).line == 2

  test "maps UTF-8 and UTF-32 positions":
    let content = "é😀"
    let utf8 = initDocumentSnapshot("file:///tmp/phase1-utf8.nim", content, 1, peUtf8)
    doAssert utf8.offsetAt(TextPosition(line: 0, character: 2)) == 2
    var invalidOffset = 0
    doAssert not utf8.tryOffsetAt(TextPosition(line: 0, character: 1), invalidOffset)

    let utf32 =
      initDocumentSnapshot("file:///tmp/phase1-utf32.nim", content, 1, peUtf32)
    doAssert utf32.offsetAt(TextPosition(line: 0, character: 2)) == content.len
    doAssert utf32.positionAt(2).character == 1

  test "verifies declaration tokens instead of substrings":
    let document = initDocumentSnapshot(
      "file:///tmp/phase2-token.nim",
      "proc exported(): int = 1\n# exported\nlet text = \"exported\"\nproc exportedly(): int = 2\n",
      1,
    )
    var startOffset, finishOffset: int
    doAssert document.tryTokenSpanAt(1, 5, "exported", startOffset, finishOffset)
    doAssert startOffset == 5
    doAssert finishOffset == 13
    doAssert not document.tryTokenSpanAt(2, 2, "exported", startOffset, finishOffset)
    doAssert not document.tryTokenSpanAt(3, 12, "exported", startOffset, finishOffset)
    doAssert not document.tryTokenSpanAt(4, 5, "exported", startOffset, finishOffset)

  test "numeric suffixes do not hide later code":
    let document = initDocumentSnapshot(
      "file:///tmp/numeric-suffix.nim",
      "let a = 0.5'f32\nlet b = 0xFF'u8\nlet c = 'x'\nproc target() = discard\n", 1,
    )
    var startOffset, finishOffset: int
    check document.tryTokenSpanAt(4, 5, "target", startOffset, finishOffset)
    check not document.tryTokenSpanAt(3, 9, "x", startOffset, finishOffset)

  test "compiler lexer distinguishes source tokens from literals and comments":
    let document = initDocumentSnapshot(
      "file:///tmp/lexer.nim",
      "let raw = r\"ends with slash\\\"\n" &
        "let text = \"\"\"target\\\nmore target\"\"\"\n" &
        "#[ outer #[ target ]# still target ]#\n" & "## target\n" &
        "proc `target`() = discard\n" & "discard target()\n",
      1,
    )
    var startOffset, finishOffset: int
    check not document.tryTokenSpanAt(2, 14, "target", startOffset, finishOffset)
    check not document.tryTokenSpanAt(3, 5, "target", startOffset, finishOffset)
    check not document.tryTokenSpanAt(4, 12, "target", startOffset, finishOffset)
    check not document.tryTokenSpanAt(5, 3, "target", startOffset, finishOffset)
    check document.tryTokenSpanAt(6, 6, "target", startOffset, finishOffset)
    check document.tryTokenSpanAt(7, 8, "target", startOffset, finishOffset)

  test "lexer accepts code before an unfinished literal":
    let document = initDocumentSnapshot(
      "file:///tmp/incomplete.nim", "discard target()\nlet text = \"unfinished", 1
    )
    var startOffset, finishOffset: int
    check document.tryTokenSpanAt(1, 8, "target", startOffset, finishOffset)
    check not document.tryTokenSpanAt(2, 12, "unfinished", startOffset, finishOffset)

  test "declaration headers retain types and omit procedure bodies":
    let document = initDocumentSnapshot(
      "file:///tmp/declaration.nim",
      "proc target*(\n    value: int = 3, text: string = \"=\"\n): bool {.raises: [].} =\n  discard\n",
      1,
    )
    let declaration = document.declarationText(1)
    check "value: int = 3" in declaration
    check "): bool {.raises: [].}" in declaration
    check "discard" notin declaration

  test "orders document overlay versions":
    var store = initDocumentStore()
    let uri = "file:///tmp/phase1-overlay.nim"
    doAssert store.openDocument(uri, "one", 1) == dusApplied
    doAssert store.openDocument(uri, "again", 1) == dusAlreadyOpen
    doAssert store.updateDocument(uri, "stale", 1) == dusIgnoredStale
    doAssert store.updateDocument(uri, "two", 2) == dusApplied
    doAssert store.findDocument(uri).content == "two"
    doAssert store.len == 1
    doAssert store.closeDocument(uri)
    doAssert not store.containsDocument(uri)
    doAssert store.updateDocument(uri, "missing", 3) == dusMissing

  test "a missing final newline does not make an open document dirty":
    let path =
      getTempDir() / ("nimdex-final-newline-" & $getCurrentProcessId() & ".nim")
    defer:
      removeFile(path)
    writeFile(path, "discard value\n")
    let uri = documentUriFromPath(path)
    var store = initDocumentStore()
    check store.openDocument(uri, "discard value", 1) == dusApplied
    check store.dirtyDocuments().len == 0
    check store.updateDocument(uri, "discard other", 2) == dusApplied
    check store.dirtyDocuments().len == 1
    check sameSourceText("one\r\n", "one")
    check not sameSourceText("one\n\n", "one")

  test "identifies workspace paths and configuration":
    let rootPath = normalizeDocumentPath(getTempDir() / "nimdex-workspace")
    let workspace = initWorkspace(
      documentUriFromPath(rootPath),
      entryPoints = @[rootPath / "src/main.nim"],
      importPaths = @[rootPath / "src"],
      nimArguments = @["--path:src"],
      artifactRoots = @[rootPath / "cache"],
      configurationGeneration = 3,
    )
    doAssert workspace.projectId == rootPath
    doAssert workspace.configurationGeneration == 3
    doAssert workspace.configurationFingerprint != 0
    doAssert workspace.containsPath(rootPath / "src/main.nim")
    doAssert not workspace.containsPath(rootPath & "-other/main.nim")
