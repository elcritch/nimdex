## Owned document snapshots, URI/path normalization, and LSP position mapping.

import std/[os, strutils, tables, unicode, uri]

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

type SourceLexMode = enum
  slCode
  slLineComment
  slBlockComment
  slString
  slChar
  slBacktick

proc tokenIsInSourceCode(document: DocumentSnapshot, offset: int): bool =
  ## Reject positions that are lexically inside comments, strings, or chars.
  ## This is deliberately conservative; the compiler position remains the
  ## authority for syntax, while this prevents accidental substring matches.
  var mode = slCode
  var blockDepth = 0
  var escaped = false
  var tripleString = false
  var cursor = 0
  while cursor < offset:
    let value = document.content[cursor]
    case mode
    of slCode:
      if value == '#' and cursor + 1 < offset and document.content[cursor + 1] == '[':
        mode = slBlockComment
        blockDepth = 1
        cursor += 2
        continue
      if value == '#':
        mode = slLineComment
      elif value == '"':
        mode = slString
        tripleString =
          cursor + 2 < offset and document.content[cursor + 1] == '"' and
          document.content[cursor + 2] == '"'
        if tripleString:
          cursor += 3
        else:
          inc cursor
        continue
      elif value == '\'':
        mode = slChar
      elif value == '`':
        mode = slBacktick
    of slLineComment:
      if value in {'\r', '\n'}:
        mode = slCode
    of slBlockComment:
      if value == '#' and cursor + 1 < offset and document.content[cursor + 1] == '[':
        inc blockDepth
        cursor += 2
        continue
      if value == ']' and cursor + 1 < offset and document.content[cursor + 1] == '#':
        dec blockDepth
        cursor += 2
        if blockDepth == 0:
          mode = slCode
        continue
    of slString, slChar:
      if escaped:
        escaped = false
      elif value == '\\':
        escaped = true
      elif tripleString:
        if value == '"' and cursor + 2 < offset and document.content[cursor + 1] == '"' and
            document.content[cursor + 2] == '"':
          mode = slCode
          tripleString = false
          cursor += 3
          continue
      elif (mode == slString and value == '"') or (mode == slChar and value == '\''):
        mode = slCode
    of slBacktick:
      if value == '`':
        mode = slCode
    inc cursor
  mode == slCode

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
  if not document.tokenIsInSourceCode(startOffset):
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
          stableTextHash(readFile(document.path)) == document.textHash:
        continue
    except CatchableError:
      discard
    result.add(document)
