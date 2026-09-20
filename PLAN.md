# Binny-backed LSP plan

Status: Phase 0 implemented. This document describes the remaining
implementation stages and the compatibility gates for each one.

## Goal

Use Binny as a safe reader of compiler-produced Nim semantic artifacts while
keeping the LSP protocol and runtime in Nimdex/Sigils. Nimdex requires a Nim
compiler that supports `--genBif:on`; this is a hard toolchain prerequisite,
not an optional enhancement.

The initial language path must work without the `deps/langserver/` language
backend and without `nimsuggest`. The generic protocol definitions in
`deps/langserver/` may be consulted, but compiler-produced BIF data and the
Binny adapter are the source of language semantics.

The intended ownership boundary is:

| Area | Owner |
| --- | --- |
| LSP lifecycle, capability negotiation, validation, JSON values, and responses | Nimdex `lsp.nim` |
| JSON-RPC method routing, Content-Length framing, signals, and thread scheduling | Sigils and Sigils JSON-RPC |
| Document buffers, workspace configuration, semantic snapshots, and language queries | Nimdex language components |
| Reading and traversing compiler BIF/NIF artifacts | Nimdex adapter over Binny |
| Compiler invocation and compiler diagnostics | Nimdex compiler integration |

`deps/langserver/` remains out of the language backend. Its generic protocol definitions may be consulted where useful, but its language implementation must not be used.

## What the reviewed Binny checkout provides

The dependency identifies itself as Binny 0.5.22 (`deps/binny/binny.nimble`); the checked-out revision is `a40e952`. The useful APIs for LSP work are the lower-level NIF/BIF reader APIs:

- `binny/bif_safe` loads an owned, validated `BifModule`, applies resource limits, reports categorized failures, and offers `tryLoad` for a non-raising workspace-scan boundary.
- `BifModule.index` records indexed global declarations with exported/hidden visibility. `declarations` enumerates them and `findDeclaration` looks up one declaration.
- `nifcore.Cursor` and `nifqueries` provide bounded tree traversal and queries such as `childCursor`, `findChildTag`, `findDescendantTag`, `symName`, `strVal`, `cursorTagId`, and `skip`.
- `rawLineInfo` and `lineInfoFile` expose compiler-emitted file/line/column metadata. The metadata is sparse and describes positions, not complete LSP ranges.
- `nifcoreparse` can create deterministic synthetic NIF fixtures, but it parses NIF text, not Nim source text.

The following Binny areas are not an LSP backend:

- `native_dynlib/build` orchestrates native-library compilation and linking.
- `native_dynlib/bifreader` reconstructs native ABI types and routines for generated dynamic-library bindings. It imports Nim compiler internals and assumes compiler/backend artifacts that are not the language-service data model.
- `elfparser`, DWARF, and SFrame modules describe compiled binaries, unwind data, and address-to-line information. They are not a replacement for source-semantic indexing.

Do not use the root `binny` import or `binny/bif` for long-lived server loading. The normal BIF loader memory-maps files, retains the mapping for process lifetime, and can terminate on malformed input. Use `binny/bif_safe` and preserve the last valid semantic snapshot when a refresh fails.

Do not call Binny's `findSemanticBifPath` directly from the server. Its implementation scans with the mmap-backed loader. Nimdex should either implement the small source-path discovery operation over `bif_safe` or add a safe helper upstream before depending on it.

## Constraints to prove first

### Compiler artifact availability

Nimdex requires a Nim devel/compiler build that advertises `--genBif:on`.
This checkout provides that baseline at `deps/nim-devel/bin/nim` (Nim 2.3.1)
along with `deps/nim-devel/bin/nifler`. The compiler capability probe must
record the exact compiler, revision, command line, Nim cache layout, and
artifact names. `nifler` is a companion inspection/discovery tool; the
server's semantic boundary remains direct, safe Binny loading.

If no configured compiler can produce the required artifacts, setup or server
initialization must fail with a clear prerequisite error. Do not fall back to
the existing language shim, `deps/langserver/`, or `nimsuggest`, and do not
advertise compiler-backed language capabilities.

### Source positions and ranges

Binny line information is encoded as sparse `LineInfoLit` data. `rawLineInfo` only reports metadata attached to the current token, so a traversal must carry the effective location while walking the tree. Declaration-name positions, inherited locations, generated nodes, and missing `modulesrc` metadata all need real-fixture tests.

The encoded wide column field is finite; lines beyond its supported width need an explicit compatibility test. BIF locations are source positions, not start/end spans, so exact LSP ranges require either source scanning or a richer compiler artifact. Never advertise range-sensitive features until this mapping is verified.

LSP positions also require a conversion layer for negotiated character encodings, with UTF-16 as the compatibility default. It must handle Unicode, CRLF, invalid client positions, and long lines independently of Binny's internal line/column representation.

### Runtime responsiveness

The current `LanguageRuntime` has one response slot and blocks each caller while pumping the local Sigils scheduler. It cannot safely represent multiple outstanding requests, and an uncaught worker exception can leave the caller waiting forever.

Sigils' `jrStdio.pollJsonRpcStdio` blocks while waiting for the next complete frame. That is sufficient for the current synchronous shim, but it cannot reliably publish diagnostics or other unsolicited notifications while stdin is idle. Sigils JSON-RPC already owns framing and outbound notification primitives; any asynchronous stdio support should be a generic Sigils/runtime improvement. Chronos may be used only through the Sigils Chronos thread, never as a separate language backend scheduler.

## Target architecture

```text
stdin/stdout Content-Length transport
                 |
       Sigils JSON-RPC dispatcher
                 |
          Nimdex LSP session
                 |
       correlated language work
                 |
       Sigils worker pool actors
          /                  \
 compiler/artifact jobs     document and snapshot state
          \                  /
          owned semantic snapshots
```

The LSP session remains responsible for protocol state and JSON serialization. Worker jobs receive immutable descriptions and return owned Nimdex records. A result is tagged with at least:

- project/workspace identity;
- compiler and configuration generation;
- document revision(s) used by the analysis;
- an internal work ID separate from the JSON-RPC request ID.

Results are installed atomically only when their stamp is still current. Superseded work must not replace a newer snapshot, but every request still needs a settled response or an explicit LSP cancellation/error response.

Keep Binny types private to the BIF extraction boundary. Do not send `Cursor`, `TokenBuf`, `Pool`, `TagPool`, `SymId`, `StrId`, or borrowed pool strings between actors. Binny's cursor owner uses a manual non-atomic reference count; atomic ARC does not make that counter thread-safe. Initially, load, traverse, extract, and destroy each BIF inside one worker call, returning copied semantic records.

Suggested boundaries, introduced only as their responsibilities become real:

| Module | Responsibility |
| --- | --- |
| `src/nimdex/lsp.nim` | Lifecycle, request validation, capability advertisement, cancellation bookkeeping, and protocol serialization. |
| `src/nimdex/documents.nim` | URI/path normalization, open-buffer versions, line indexes, overlays, and LSP position encoding. |
| `src/nimdex/workspace.nim` | Roots, entry points, Nim arguments/import paths, configuration fingerprints, and invalidation. |
| `src/nimdex/bifindex.nim` | Safe BIF discovery/loading, schema-aware traversal, effective source locations, and conversion to owned records. |
| `src/nimdex/semantic.nim` | `DocumentSnapshot`, `AnalysisStamp`, `SymbolInfo`, `Occurrence`, locations, lookup tables, and analysis failures. |
| `src/nimdex/compiler.nim` | Compiler capability probing, controlled artifact generation, process results, and diagnostic extraction. |
| `src/nimdex/language.nim` | Sigils worker-pool coordination, queueing, snapshot installation, and response/notification completion. |

Neither the Binny adapter nor semantic modules should depend on JSON or LSP protocol types.

## Implementation phases

### Phase 0: compatibility and evidence fixtures

Build a small real Nim fixture containing imports, public and private declarations, overloads, generics, macros, locals, Unicode identifiers/text, CRLF, and lines longer than the BIF column width.

Establish:

- which compiler invocation emits `.s.bif` files;
- how a BIF maps to its source module and compiler configuration;
- which tags represent declarations, types, routines, parameters, and uses;
- whether documentation and visibility survive into the artifact;
- how sparse locations attach to declaration names and references;
- whether generated nodes can be mapped back to a source URI.

Load artifacts with `binny/bif_safe`, using explicit daemon-sized limits. Exercise `tryLoad` against missing, truncated, incompatible, malformed, and over-limit files. Verify that a failed refresh leaves the previous valid module/snapshot untouched.

Completion criterion: a checked-in or reproducible fixture generated by the
project-local `--genBif` compiler plus a written compatibility matrix. No LSP
capability is promoted based only on synthetic BIF data.

### Phase 1: documents and offline BIF indexing

Add the document and workspace value objects first. Track URI, normalized source path, client version, text hash, line index, position encoding, project identity, and configuration generation.

Implement `bifindex` as an offline worker operation:

1. discover candidate `.s.bif` files without the mmap loader;
2. safely load one artifact;
3. validate the expected semantic tags and metadata after binary validation;
4. walk declarations and relevant children while carrying effective line information;
5. copy names, visibility, qualified compiler identity, signatures where proven, and source positions into owned records;
6. build name and location lookup tables once per snapshot rather than calling the linear `findDeclaration` path for every query;
7. destroy Binny storage before the worker result is returned.

Use qualified project/module identities for symbol keys. Numeric pool IDs and cursor addresses are local implementation details and must not become workspace identifiers.

Do not keep the existing language shim as a semantic fallback. Full document
synchronization updates the authoritative overlay, but must not pretend that
the compiler artifact has been rebuilt from unsaved text. Until compiler-backed
analysis is available, return a clear configuration/analysis-unavailable error
instead of presenting shim results as language semantics.

### Phase 2: first Binny-backed LSP queries

Advertise capabilities only after their source mapping is tested. Start with the least ambitious global queries:

- `textDocument/documentSymbol` for declarations with verified locations;
- `workspace/symbol` over installed module snapshots;
- `textDocument/hover` for verified declaration/signature information;
- `textDocument/definition` only after symbol-use to declaration matching is proven.

The first hover implementation should return a clear `null` or “analysis
unavailable” result when the current open buffer differs from the indexed
source and no overlay analysis exists. It must not return stale positions as if
they described the current buffer. This is an unavailable-analysis result, not
a fallback to the existing language shim.

Keep references, rename, completion, formatting, code actions, semantic tokens, call/type hierarchy, and scope-aware local symbol queries deferred. The reviewed Binny APIs do not establish the required scope, reference, edit, or validation semantics.

### Phase 3: responsive asynchronous runtime

Before compiler refreshes run in the background, replace the single response slot with explicit correlated work state:

- map internal work IDs to pending requests and completion callbacks;
- settle all pending requests on success, failure, cancellation, worker exception, and shutdown;
- preserve document-notification ordering;
- bound queue growth and define cancellation checkpoints;
- prevent a completed old job from publishing over a newer document/configuration stamp;
- provide an idle-input path that can flush completed responses and outbound diagnostics.

Extend Sigils generically where needed for deferred JSON-RPC completion and responsive stdio. Do not return a placeholder response and later emit a second response with the same ID. Preserve `jrStdio` framing and keep stdout exclusively for framed JSON-RPC bytes.

### Phase 4: compiler refresh and diagnostics

Add a project-aware compiler worker that:

- requires and records compiler capabilities, including `--genBif:on`;
- runs a controlled artifact-generation command in a project-specific cache;
- captures compiler stdout/stderr and exit status;
- discovers BIFs by normalized source path;
- fingerprints compiler version, arguments, import paths, configuration, and source revisions;
- converts compiler failures into owned diagnostics;
- installs a complete new semantic snapshot atomically.

Failed, cancelled, or superseded builds must not replace a good snapshot. Publish diagnostics only for the matching project/configuration/document stamp, and clear them after a matching successful analysis.

### Phase 5: unsaved-buffer analysis and richer features

Define a compiler overlay strategy that preserves source paths, imports, configuration, and generated-artifact mapping without writing client text over workspace files. Full synchronization alone is not an overlay.

Until the overlay exists, suppress position-sensitive semantic results for changed buffers or mark them explicitly as stale/unavailable. After overlay analysis is reliable, expand to references, document highlights, completion, richer hover signatures, and other features based on verified semantic records.

## API and ownership rules

Use named Nimdex value objects such as `DocumentSnapshot`, `AnalysisStamp`, `SymbolInfo`, `Occurrence`, `SourceLocation`, and `AnalysisFailure`. Distinguish:

- no matching symbol;
- analysis unavailable because artifacts/tooling are missing;
- cancellation or supersession;
- malformed/incompatible artifact;
- compiler failure;
- internal worker failure.

Use `sink` only where ownership is intentionally transferred, and verify that Sigils message construction does not retain aliases into worker-owned data. Expose copied strings and sequences at the language boundary. Keep LSP JSON conversion at the outer layer.

Document changes must be version-ordered. The current parser ignores the `range` field and treats the last change text as a complete replacement; until ranged edits are implemented, reject ranged changes instead of silently corrupting the document state.

## Test and verification plan

Add deterministic tests as each phase lands:

- safe BIF loading: missing files, bad magic/version, truncation, invalid tokens/indexes, resource limits, malformed semantic trees, missing `modulesrc`, and preservation of the prior snapshot;
- synthetic BIF/NIF traversal for declaration visibility, tags, symbol qualification, and sparse location inheritance;
- real compiler fixtures for imports, overloads, generics, macros, locals, Unicode/UTF-16, CRLF, long lines, generated symbols, and source mapping;
- document version ordering, URI/path normalization, close/reopen behavior, and overlay/source mismatch handling;
- workspace and document symbol lookup, hover/definition nullability, stale result rejection, and configuration-generation changes;
- multiple outstanding JSON-RPC requests, cancellation/completion races, worker exceptions, shutdown during indexing, fragmented frames, EOF, and diagnostics while stdin is idle;
- repeated BIF load/extract/destroy cycles with one and multiple Sigils workers under the repository's atomic-ARC configuration.

Use synthetic fixtures for malformed-input coverage, but require real compiler artifacts before enabling a source-semantic LSP capability. Run the repository's normal Atlas test commands and format touched Nim files with `nph` when implementation begins.

## Acceptance criteria

The Binny integration is ready for the first production-facing LSP feature when:

1. Nimdex uses `binny/bif_safe` and never exposes Binny cursors or pools outside the extraction worker.
2. Startup/setup fails clearly when the configured Nim compiler lacks
   `--genBif:on`; Nimdex does not require `deps/langserver/` or
   `nimsuggest` as a language backend.
3. A real compiler fixture proves the advertised source locations and LSP character conversions.
4. Snapshot stamps prevent stale compiler results from replacing newer document/configuration state.
5. JSON-RPC responses remain correctly correlated, and worker failures/cancellation cannot strand requests.
6. Background diagnostics and results can be flushed while stdin is idle through a Sigils-owned transport/runtime path.
7. No language backend from `deps/langserver/` is imported.

## Open decisions

- Which supported Nim compiler/devel revision is the minimum beyond the
  project-local `deps/nim-devel` baseline for reproducible BIF generation?
- Should safe BIF source-path discovery be a Nimdex implementation or an upstream Binny helper?
- Which BIF tags and compiler metadata are stable enough to form the first semantic schema?
- What is the exact responsive stdio design in Sigils, and where should the Sigils Chronos thread participate?
- How will compiler overlays preserve import/configuration semantics for unsaved buffers?
- Which LSP capabilities can be backed by declaration positions before exact ranges and reference resolution are available?
