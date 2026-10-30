## Owned document snapshots, URI/path normalization, and LSP position mapping.

import std/[os, strutils, tables, unicode, uri]

import compiler/[idents, lexer, lineinfos, llstream, options, pathutils]

type
  PositionEncoding* = enum
    peUtf16
    peUtf8
    peUtf32

  TextPosition* = object
    line*: int
    character*: int

  DocumentSnapshot* = object
    ## An immutable-by-convention copy of one client document version.
    uri*: string
    path*: string
    version*: int
    content*: string
    textHash*: uint64
    positionEncoding*: PositionEncoding
    lineStarts: seq[int]

  DocumentUpdateStatus* = enum
    dusApplied
    dusAlreadyOpen
    dusMissing
    dusIgnoredStale

  DocumentStore* = object
    ## Worker-owned document overlays keyed by canonical document URI.
    documents: Table[string, DocumentSnapshot]

proc stableTextHash*(text: string): uint64 =
  ## Return a deterministic, process-independent content fingerprint.
  const
    offsetBasis = 1469598103934665603'u64
    prime = 1099511628211'u64
  result = offsetBasis
  for value in text:
    result = (result xor uint64(ord(value))) * prime

proc sameSourceText*(a, b: string): bool =
  ## A final line terminator does not change any compiler token positions.
  if a == b:
    return true
  let shorter = if a.len < b.len: a else: b
  let longer = if a.len < b.len: b else: a
  if longer.len == shorter.len + 1 and longer[^1] == '\n':
    return longer.startsWith(shorter)
  if longer.len == shorter.len + 2 and longer.endsWith("\r\n"):
    return longer.startsWith(shorter)

proc normalizeDocumentPath*(path: string): string =
  ## Canonicalize existing ancestors too: compiler BIFs resolve symlinks, and
  ## new/missing documents must retain the same identity before and after save.
  if path.len == 0:
    return
  result = path
  when defined(windows):
    result = result.replace('/', '\\')
  result = absolutePath(result)
  result = normalizedPath(result)
  var ancestor = result
  var suffix: seq[string]
  while not fileExists(ancestor) and not dirExists(ancestor):
    let parent = ancestor.parentDir
    if parent == ancestor:
      break
    suffix.add(ancestor.lastPathPart)
    ancestor = parent
  try:
    result = expandFilename(ancestor)
    for index in countdown(suffix.high, 0):
      result = result / suffix[index]
  except OSError:
    discard

proc encodeUriPath(path: string): string =
  let segments = path.split('/')
  for index, segment in segments:
    if index > 0:
      result.add('/')
    var encoded = encodeUrl(segment, usePlus = false)
    encoded = encoded.replace("%3A", ":")
    encoded = encoded.replace("%3a", ":")
    result.add(encoded)

proc documentUriFromPath*(path: string): string =
  ## Convert a local path to a canonical file URI.
  let normalized = normalizeDocumentPath(path)
  if normalized.len == 0:
    return

  var uriPath = normalized
  uriPath = uriPath.replace(DirSep, '/')
  when defined(windows):
    if uriPath.len >= 2 and uriPath[1] == ':':
      uriPath = "/" & uriPath
  result = "file://" & encodeUriPath(uriPath)

proc pathFromDocumentUri*(uri: string): string =
  ## Return a normalized local path for a file URI, or an empty string for
  ## other document schemes.
  if uri.len == 0:
    return

  var parsed: Uri
  try:
    parsed = parseUri(uri)
  except UriParseError as error:
    raise newException(ValueError, "invalid document URI: " & error.msg)

  if parsed.scheme.len == 0:
    return normalizeDocumentPath(uri)
  if parsed.scheme.toLowerAscii() != "file":
    return

  var path = decodeUrl(parsed.path, decodePlus = false)
  if parsed.hostname.len > 0 and parsed.hostname.toLowerAscii() != "localhost":
    path = "//" & parsed.hostname & path
  when defined(windows):
    if path.len >= 3 and path[0] == '/' and path[2] == ':':
      path = path[1 .. ^1]
    path = path.replace('/', DirSep)
  result = normalizeDocumentPath(path)

proc normalizeDocumentUri*(uri: string): string =
  ## Canonicalize file URIs while preserving non-file document schemes.
  if uri.len == 0:
    return
  let path = pathFromDocumentUri(uri)
  if path.len > 0:
    return documentUriFromPath(path)

  var parsed: Uri
  try:
    parsed = parseUri(uri)
  except UriParseError as error:
    raise newException(ValueError, "invalid document URI: " & error.msg)
  if parsed.scheme.len == 0:
    return documentUriFromPath(uri)
  uri

proc buildLineStarts(content: string): seq[int] =
  result.add(0)
  var cursor = 0
  while cursor < content.len:
    case content[cursor]
    of '\r':
      inc cursor
      if cursor < content.len and content[cursor] == '\n':
        inc cursor
      result.add(cursor)
    of '\n':
      inc cursor
      result.add(cursor)
    else:
      inc cursor

proc lineBounds(document: DocumentSnapshot, line: int): tuple[start, finish: int] =
  if line < 0 or line >= document.lineStarts.len:
    raise newException(ValueError, "document line is out of range")
  result.start = document.lineStarts[line]
  result.finish =
    if line + 1 < document.lineStarts.len:
      document.lineStarts[line + 1]
    else:
      document.content.len
  while result.finish > result.start and
      document.content[result.finish - 1] in {'\r', '\n'}:
    dec result.finish

proc lineCount*(document: DocumentSnapshot): int =
  ## Return the number of logical lines, including a final empty line.
  document.lineStarts.len

proc lineStartOffset*(document: DocumentSnapshot, line: int): int =
  document.lineBounds(line).start

proc lineEndOffset*(document: DocumentSnapshot, line: int): int =
  document.lineBounds(line).finish

proc lineText*(document: DocumentSnapshot, line: int): string =
  let bounds = document.lineBounds(line)
  if bounds.finish > bounds.start:
    result = document.content[bounds.start ..< bounds.finish]

proc lineForOffset(document: DocumentSnapshot, offset: int): int =
  if offset < 0 or offset > document.content.len:
    raise newException(ValueError, "document offset is out of range")
  var low = 0
  var high = document.lineStarts.len
  while low < high:
    let middle = (low + high) div 2
    if document.lineStarts[middle] <= offset:
      low = middle + 1
    else:
      high = middle
  max(0, low - 1)

proc isUtf8Continuation(value: char): bool =
  (ord(value) and 0xc0) == 0x80

proc runeUnits(rune: Rune, encoding: PositionEncoding): int =
  case encoding
  of peUtf8:
    rune.size
  of peUtf16:
    if int(rune) > 0xffff: 2 else: 1
  of peUtf32:
    1

proc tryOffsetAt*(
    document: DocumentSnapshot, position: TextPosition, offset: var int
): bool =
  ## Convert a client position to a byte offset without accepting invalid
  ## lines, character units, or positions inside a UTF-8 sequence.
  if position.line < 0 or position.character < 0:
    return false
  let bounds =
    try:
      document.lineBounds(position.line)
    except ValueError:
      return false

  case document.positionEncoding
  of peUtf8:
    if position.character > bounds.finish - bounds.start:
      return false
    offset = bounds.start + position.character
    if offset < bounds.finish and document.content[offset].isUtf8Continuation:
      return false
    true
  of peUtf16, peUtf32:
    var cursor = bounds.start
    var units = 0
    while cursor < bounds.finish:
      let runeStart = cursor
      var rune: Rune
      fastRuneAt(document.content, cursor, rune)
      let width = runeUnits(rune, document.positionEncoding)
      if units == position.character:
        offset = runeStart
        return true
      if units + width > position.character:
        return false
      units += width
    if units == position.character:
      offset = bounds.finish
      return true
    false

proc offsetAt*(document: DocumentSnapshot, position: TextPosition): int =
  if not document.tryOffsetAt(position, result):
    raise newException(
      ValueError, "document position is outside the line or splits a character"
    )

proc tryPositionAt*(
    document: DocumentSnapshot, offset: int, position: var TextPosition
): bool =
  if offset < 0 or offset > document.content.len:
    return false
  let line = document.lineForOffset(offset)
  let bounds = document.lineBounds(line)
  let target = min(offset, bounds.finish)
  position.line = line

  case document.positionEncoding
  of peUtf8:
    if target < bounds.finish and document.content[target].isUtf8Continuation:
      return false
    position.character = target - bounds.start
    true
  of peUtf16, peUtf32:
    var cursor = bounds.start
    var units = 0
    while cursor < target:
      let runeStart = cursor
      var rune: Rune
      fastRuneAt(document.content, cursor, rune)
      if cursor > target:
        return false
      units += runeUnits(rune, document.positionEncoding)
      if cursor == runeStart:
        return false
    if cursor != target:
      return false
    position.character = units
    true

proc positionAt*(document: DocumentSnapshot, offset: int): TextPosition =
  if not document.tryPositionAt(offset, result):
    raise newException(ValueError, "document offset is inside a UTF-8 character")

proc isIdentifierByte(value: char): bool =
  value == '_' or value.isAlphaNumeric or (ord(value) and 0x80) != 0

proc ignoreLexerError(conf: ConfigRef, info: TLineInfo, msg: TMsgKind, arg: string) =
  ## Editor buffers may be incomplete; lexical errors must not terminate Nimdex.
  discard

proc tokenIsInSourceCode(document: DocumentSnapshot, line, column: int): bool =
  ## A compiler token must begin at this exact position. This rejects matching
  ## text inside strings and comments without duplicating Nim's lexical rules.
  var lex: Lexer
  let config = newConfigRef()
  let filename =
    if document.path.len > 0:
      document.path
    else:
      getCurrentDir() / "buffer.nim"
  openLexer(
    lex, AbsoluteFile(filename), llStreamOpen(document.content), newIdentCache(), config
  )
  lex.errorHandler = ignoreLexerError
  defer:
    closeLexer(lex)
  var token: Token
  while true:
    rawGetTok(lex, token)
    if token.tokType == tkEof or token.line > line or
        (token.line == line and token.col > column):
      break
    if token.line == line and token.col == column:
      return token.tokType notin {tkInvalid, tkComment, tkIntLit .. tkCustomLit}

proc declarationText*(document: DocumentSnapshot, compilerLine: int32): string =
  ## Read a bounded declaration header from the validated source document.
  let line = int(compilerLine) - 1
  if line < 0 or line >= document.lineCount:
    return
  let firstLine = document.lineText(line)
  let trimmed = firstLine.strip()
  if trimmed.len == 0:
    return
  let routine =
    strutils.splitWhitespace(trimmed)[0] in
    ["proc", "func", "method", "iterator", "converter", "template", "macro"]
  if not routine:
    return trimmed.substr(0, 1023)

  let start = document.lineStartOffset(line)
  let lastLine = min(document.lineCount - 1, line + 40)
  let limit = min(
    document.content.len, min(start + 8192, document.lineStartOffset(lastLine) + 4096)
  )
  let fragment = document.content[start ..< limit]
  var lex: Lexer
  let config = newConfigRef()
  let filename =
    if document.path.len > 0:
      document.path
    else:
      getCurrentDir() / "buffer.nim"
  openLexer(
    lex, AbsoluteFile(filename), llStreamOpen(fragment), newIdentCache(), config
  )
  lex.errorHandler = ignoreLexerError
  defer:
    closeLexer(lex)
  var token: Token
  var depth = 0
  let indentation =
    firstLine.len - firstLine.strip(leading = true, trailing = false).len
  var finish = fragment.len
  while true:
    rawGetTok(lex, token)
    if token.tokType == tkEof:
      break
    if token.line > 1 and token.indent >= 0 and token.indent <= indentation and
        depth == 0:
      finish = document.lineStartOffset(line + token.line - 1) - start + token.col
      break
    if token.tokType == tkEquals and depth == 0:
      finish = document.lineStartOffset(line + token.line - 1) - start + token.col
      break
    case token.tokType
    of tkParLe, tkBracketLe, tkCurlyLe, tkCurlyDotLe, tkBracketDotLe, tkParDotLe:
      inc depth
    of tkParRi, tkBracketRi, tkCurlyRi, tkCurlyDotRi, tkBracketDotRi, tkParDotRi:
      depth = max(0, depth - 1)
    else:
      discard
  result = fragment[0 ..< min(finish, 4096)].strip()

proc parameterDeclarationText*(
    document: DocumentSnapshot, compilerLine, compilerColumn: int32
): string =
  ## A parameter may share its source line with its enclosing routine.
  let line = int(compilerLine) - 1
  if line < 0 or line >= document.lineCount or compilerColumn < 0:
    return
  let start = document.lineStartOffset(line) + int(compilerColumn)
  if start >= document.content.len:
    return
  let fragment = document.content[start ..< min(document.content.len, start + 4096)]
  var lex: Lexer
  let config = newConfigRef()
  let filename =
    if document.path.len > 0:
      document.path
    else:
      getCurrentDir() / "buffer.nim"
  openLexer(
    lex, AbsoluteFile(filename), llStreamOpen(fragment), newIdentCache(), config
  )
  lex.errorHandler = ignoreLexerError
  defer:
    closeLexer(lex)
  var token: Token
  var depth = 0
  var finish = fragment.len
  while true:
    rawGetTok(lex, token)
    if token.tokType == tkEof:
      break
    if depth == 0 and token.tokType in {tkComma, tkSemiColon, tkParRi}:
      finish =
        if token.line == 1:
          token.col
        else:
          document.lineStartOffset(line + token.line - 1) - start + token.col
      break
    case token.tokType
    of tkParLe, tkBracketLe, tkCurlyLe, tkCurlyDotLe, tkBracketDotLe, tkParDotLe:
      inc depth
    of tkParRi, tkBracketRi, tkCurlyRi, tkCurlyDotRi, tkBracketDotRi, tkParDotRi:
      depth = max(0, depth - 1)
    else:
      discard
  result = fragment[0 ..< finish].strip()

proc tryTokenSpanAt*(
    document: DocumentSnapshot,
    compilerLine, compilerColumn: int32,
    token: string,
    startOffset, finishOffset: var int,
): bool =
  ## Find a declaration token exactly at a compiler source position.
  ## Compiler line numbers are one-based and columns are byte offsets.
  if token.len == 0 or compilerLine <= 0 or compilerColumn < 0:
    return false
  let line = int(compilerLine) - 1
  let text =
    try:
      document.lineText(line)
    except ValueError:
      return false
  let column = int(compilerColumn)
  if column >= text.len:
    return false
  var finish = column
  if text[column] == '`':
    let closing = text.find('`', column + 1)
    if closing < 0:
      return false
    let actual = text[column + 1 ..< closing]
    if actual != token and
        (actual.len == 0 or actual[0] != token[0] or cmpIgnoreStyle(actual, token) != 0):
      return false
    finish = closing + 1
  elif column > 0 and text[column - 1] == '`':
    return document.tryTokenSpanAt(
      compilerLine, compilerColumn - 1, token, startOffset, finishOffset
    )
  elif text[column].isIdentifierByte and token[0].isIdentifierByte:
    while finish < text.len and text[finish].isIdentifierByte:
      inc finish
    let actual = text[column ..< finish]
    # Nim identifiers preserve the first character's case; subsequent ASCII
    # letters ignore case and underscores. Compare the entire source token.
    if actual[0] != token[0] or cmpIgnoreStyle(actual, token) != 0:
      return false
  else:
    finish = column + token.len
    if finish > text.len or text[column ..< finish] != token:
      return false
  if column > 0 and text[column - 1].isIdentifierByte:
    return false
  if finish < text.len and text[finish].isIdentifierByte:
    return false
  startOffset = document.lineStartOffset(line) + column
  finishOffset = document.lineStartOffset(line) + finish
  if not document.tokenIsInSourceCode(int(compilerLine), column):
    return false
  var position: TextPosition
  document.tryPositionAt(startOffset, position) and
    document.tryPositionAt(finishOffset, position)

proc initDocumentSnapshot*(
    uri, content: string, version: int, positionEncoding = peUtf16
): DocumentSnapshot =
  result.uri = normalizeDocumentUri(uri)
  result.path = pathFromDocumentUri(result.uri)
  result.version = version
  result.content = content
  result.textHash = stableTextHash(content)
  result.positionEncoding = positionEncoding
  result.lineStarts = buildLineStarts(content)

proc initDocumentStore*(): DocumentStore =
  result.documents = initTable[string, DocumentSnapshot]()

proc canonicalDocumentKey(uri: string): string =
  let normalized = normalizeDocumentUri(uri)
  if normalized.len > 0: normalized else: uri

proc openDocument*(
    store: var DocumentStore,
    uri, content: string,
    version: int,
    positionEncoding = peUtf16,
): DocumentUpdateStatus =
  let key = canonicalDocumentKey(uri)
  if key in store.documents:
    return dusAlreadyOpen
  store.documents[key] = initDocumentSnapshot(key, content, version, positionEncoding)
  dusApplied

proc updateDocument*(
    store: var DocumentStore,
    uri, content: string,
    version: int,
    positionEncoding = peUtf16,
): DocumentUpdateStatus =
  let key = canonicalDocumentKey(uri)
  if key notin store.documents:
    return dusMissing
  let previous = store.documents[key]
  if version <= previous.version:
    return dusIgnoredStale
  store.documents[key] = initDocumentSnapshot(key, content, version, positionEncoding)
  dusApplied

proc closeDocument*(store: var DocumentStore, uri: string): bool =
  let key = canonicalDocumentKey(uri)
  if key notin store.documents:
    return false
  store.documents.del(key)
  true

proc containsDocument*(store: DocumentStore, uri: string): bool =
  canonicalDocumentKey(uri) in store.documents

proc findDocument*(store: DocumentStore, uri: string): DocumentSnapshot =
  let key = canonicalDocumentKey(uri)
  if key notin store.documents:
    raise newException(KeyError, "document is not open: " & uri)
  store.documents[key]

proc tryFindDocument*(
    store: DocumentStore, uri: string, document: var DocumentSnapshot
): bool =
  let key = canonicalDocumentKey(uri)
  if key notin store.documents:
    return false
  document = store.documents[key]
  true

proc len*(store: DocumentStore): int =
  store.documents.len

proc dirtyDocuments*(store: DocumentStore): seq[DocumentSnapshot] =
  ## Open buffers whose current contents differ from the filesystem.
  for document in store.documents.values:
    try:
      if fileExists(document.path) and
          sameSourceText(readFile(document.path), document.content):
        continue
    except CatchableError:
      discard
    result.add(document)
