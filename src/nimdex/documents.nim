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
  ## Make a path absolute and collapse platform-native separators and dots.
  if path.len == 0:
    return
  result = path
  when defined(windows):
    result = result.replace('/', '\\')
  result = absolutePath(result)
  result = normalizedPath(result)

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
