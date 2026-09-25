# Binny-backed LSP plan

Status: Phases 0–4b and the first Phase 5 block are implemented. Phase 4c now includes progressive head loading,
failure isolation, context selection, and persistent semantic records.
Per-head `nim track` integration is implemented as an opt-in frontend; compiler
artifact sharing across heads remains unimplemented. Phase 5 now supplies
cancellable compiler supervision, versioned dirty-buffer analysis, definitions,
static `raises` hover information, and bounded occurrence caching. This document describes
the remaining implementation stages and the compatibility gates for each one.

## Next work in order

1. Extend the repeatable edit/reopen soak to hours, larger projects, and Linux/
   Windows CI. Track daemon and compiler RSS separately, cancellation of child
   processes, failed edit recovery, and latency under queued requests.
2. Complete diagnostic persistence for skipped `nim track` modules before
   making that frontend the default. Dirty buffers currently use the verified
   `c --compileOnly:on --trackDirty` path.
3. Load lightweight ownership metadata before full semantic records, add a
   resident-head budget, and evict unreferenced persistent records/compiler
   artifacts. Open buffers and recent queries now guide the occurrence cache.
4. Add references with explicit workspace completeness and actual-head context.
   Extend definition fixtures for more macro-generated and multiline generic
   call forms; keep unverified source mappings unavailable.
5. Validate reuse of compiler artifacts across compatible heads, starting with
   prefilling separate head caches. Track arbitrary compile-time inputs
   separately from source/configuration dependencies.

Keep the `nim check --genBif:on` compiler fix as an alternative frontend path
and synthetic import batches as an optional background experiment. Neither is
a prerequisite for integrating the existing `nim track` frontend. Validate the
pinned toolchain, including companion executables, in hosted CI.

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

Binny retains the 0.5.22 package version; Nimdex now pins revision
`d21498d11ad5938b5e1371da07e64c91e7bb54d6` in `nimdex.nimble` for the token-buffer
lifetime fix. The useful APIs for LSP work are the lower-level NIF/BIF reader APIs:

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
along with `deps/nim-devel/bin/nifler` and `deps/nim-devel/bin/nifmake`.
The compiler capability probe must
record the exact compiler, revision, command line, Nim cache layout, and
artifact names. The incremental frontend requires both companion executables:
`nifler` parses sources and dependencies, and `nifmake` schedules module work.
Probe this frontend separately from `--genBif` support; the server's semantic
boundary remains direct, safe Binny loading.

If no configured compiler can produce the required artifacts, setup or server
initialization must fail with a clear prerequisite error. Do not fall back to
the existing language shim, `deps/langserver/`, or `nimsuggest`, and do not
advertise compiler-backed language capabilities.

### Source positions and ranges

Binny line information is encoded as sparse `LineInfoLit` data. `rawLineInfo` only reports metadata attached to the current token, so a traversal must carry the effective location while walking the tree. Declaration-name positions, inherited locations, generated nodes, and missing `modulesrc` metadata all need real-fixture tests.

The encoded wide column field is finite; lines beyond its supported width need an explicit compatibility test. BIF locations are source positions, not start/end spans, so exact LSP ranges require either source scanning or a richer compiler artifact. Never advertise range-sensitive features until this mapping is verified.

LSP positions also require a conversion layer for negotiated character encodings, with UTF-16 as the compatibility default. It must handle Unicode, CRLF, invalid client positions, and long lines independently of Binny's internal line/column representation.

### Runtime responsiveness

The original `LanguageRuntime` had one response slot and blocked each caller
while pumping the local Sigils scheduler. Phase 3 replaced it with correlated
work, cancellation, and bounded queues.

Sigils' `jrStdio.pollJsonRpcStdio` blocks while waiting for the next complete
frame. Phase 3 places input reading on a dedicated transport actor so the home
scheduler can publish responses and diagnostics while stdin is idle. Sigils
JSON-RPC retains framing and outbound notification ownership. Chronos may be
used only through the Sigils Chronos thread, never as a separate language
backend scheduler.

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
| `src/nimdex/semantic.nim` | `AnalysisStamp`, `SymbolInfo`, `Occurrence`, locations, lookup tables, and analysis failures. |
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

Implemented in the current tree. Document snapshots, workspace identity,
position encoding conversion, and the owned semantic snapshot are in place.
`bifindex` discovers artifacts without Binny's mmap-backed convenience loader,
then uses one independent Sigils actor per artifact to load, traverse, and
convert BIF data in parallel. The caller sorts owned results before installing
the snapshot so worker completion order cannot change query results. The LSP
document actor now owns the authoritative version-ordered overlay, rejects
ranged edits, and reports analysis-unavailable rather than returning shim
semantics until compiler-backed refresh is implemented.

The document and workspace value objects track URI, normalized source path,
client version, text hash, line index, position encoding, project identity,
and configuration generation.

`bifindex` is an offline worker operation that:

1. discover candidate `.s.bif` files without the mmap loader;
2. safely load one artifact;
3. validate the expected semantic tags and metadata after binary validation;
4. walk declarations and relevant children while carrying effective line information;
5. copy names, visibility, qualified compiler identity, signatures where proven, and source positions into owned records;
6. build name and location lookup tables once per snapshot rather than calling the linear `findDeclaration` path for every query;
7. destroy Binny storage before the worker result is returned.

Qualified project/module identities are used for symbol keys. Numeric pool IDs
and cursor addresses remain local implementation details and do not become
workspace identifiers.

Do not keep the existing language shim as a semantic fallback. Full document
synchronization updates the authoritative overlay, but must not pretend that
the compiler artifact has been rebuilt from unsaved text. Until compiler-backed
analysis is available, return a clear configuration/analysis-unavailable error
instead of presenting shim results as language semantics.

### Phase 2: first Binny-backed LSP queries

Implemented in the current tree. The server accepts artifact roots through
`newNimdexLspServer`/`runNimdexLspStdio` or
`initialize.initializationOptions.artifactRoots`. It builds and installs one
owned semantic snapshot during `initialized`, using the existing Sigils
worker-pool BIF indexer, and advertises only the verified Phase 2 capabilities
when artifact roots are configured.

The language actor returns owned, encoding-adjusted ranges across the Sigils
boundary. `documentSymbol`, `workspace/symbol`, and declaration hover are
implemented as `SymbolInformation`-style results. Disk and open-buffer content
must match the indexed source fingerprint, and a source newer than its BIF is
treated as stale; stale or unverifiable locations are omitted. Definition and
all reference/edit/completion features remain deferred.

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

Implemented in the current tree. `LanguageRuntime` now assigns internal work
IDs, keeps separate active/retired reservations, returns owned completion
records, enforces a bounded queue, and uses shared cancellation checkpoints.
Language queries carry document/configuration stamps; stale completions are
rejected before publication. LSP request IDs are correlated independently of
those internal IDs, `$/cancelRequest` settles exactly one request, and
shutdown defers its response until admitted language work has retired.

The LSP stdio path uses a reader-only `JsonRpcIoAgent` on a dedicated Sigils
thread and keeps the framed writer on the home thread. This lets the home
scheduler pump Sigils worker completions and flush JSON-RPC responses while
stdin is idle. The existing Sigils framing and dispatcher output primitives
remain the transport boundary; no dependency-local Sigils changes are needed
for this phase.

The completed runtime now provides explicit correlated work state before
compiler refreshes are introduced:

- map internal work IDs to pending requests and completion callbacks;
- settle all pending requests on success, failure, cancellation, worker exception, and shutdown;
- preserve document-notification ordering;
- bound queue growth and define cancellation checkpoints;
- prevent a completed old job from publishing over a newer document/configuration stamp;
- provide an idle-input path that can flush completed responses and outbound diagnostics.

The implementation uses the existing Sigils JSON-RPC dispatcher output and
framing primitives, with a Nimdex reader-only transport actor for responsive
stdio. It does not return a placeholder response and later emit a second
response with the same ID. `jrStdio` framing is preserved and stdout remains
exclusively framed JSON-RPC bytes.

### Phase 4: compiler refresh and diagnostics

Implemented in the current tree. `src/nimdex/compiler.nim` probes and records
the configured Nim compiler, requires `--genBif:on`, and runs a controlled
artifact-only command in a compiler/configuration/head-specific cache. The
compiler worker runs on a dedicated Sigils thread so blocking process I/O does
not occupy a language-pool worker; the generated BIFs are then loaded and
indexed through the existing parallel Sigils worker-pool path.

The refresh result owns:

- compiler capability evidence, including the version/revision and exact
  `--genBif` support check;
- separate compiler stdout/stderr and exit status;
- a normalized cache path and source/configuration/compiler fingerprints;
- owned diagnostics converted from compiler output;
- a complete semantic snapshot whose `AnalysisStamp` records the build
  generation.

The LSP server discovers explicit `initializationOptions` values for
`compilerPath`/`compiler`, `entryPoints`, `importPaths`, `nimArguments`, and
`cacheRoot`. Phase 4b extends discovery to Nimble source directories, declared
binaries, package modules, and default test heads. A configured compiler that is
missing or lacks `--genBif:on` fails initialization with a prerequisite error;
Nimdex does not silently fall back to `nimsuggest`, `deps/langserver/`, or the
old language shim.

Refreshes carry document/configuration/compiler stamps. Phase 4c publishes
independently validated head snapshots and isolates failed contexts. Cancelled
or superseded work cannot publish over newer source generations. Matching compiler output is published with LSP
`textDocument/publishDiagnostics` notifications, and a matching successful
refresh replaces the diagnostic set (including clearing old diagnostics).
Full synchronization remains an overlay only: compiler refreshes read
workspace files, so changed unsaved buffers continue to suppress stale
position-sensitive results until Phase 5's overlay strategy exists.

### Phase 4b: project discovery, actual heads, and incremental indexing

Starting point (2026-09-24): discovery only recognized root
`main.nim`/directory-named modules, refresh hashed every source in `deps/`, all
heads wrote into one cache (overwriting context-dependent BIFs), and the
indexer built a location table for every token. This phase addressed those
issues.

Implemented and verified with `deps/nim-devel/bin/nim`:

- Discover literal Nimble `srcDir` and `bin` metadata without executing package
  tasks. Find package/main modules under that source directory and default
  `tests/t*.nim` heads. Explicit entry points remain authoritative. Report
  unsupported dynamic metadata so clients can configure it explicitly.
- Read resolved `import` suffixes and `include` paths from BIF metadata. Build
  forward/reverse module graphs and map each source/include to all actual
  compiler heads that reach it. A head remains a head even when another head
  imports it; graph indegree alone cannot identify compilation contexts.
- Keep compiler caches separate by compiler/configuration/head. Share extracted
  records only for identical BIF content; the same path/suffix can have different
  semantics under test config, defines, or `isMainModule`.
- Keep successful per-head analyses in the LSP session. Validate source/include
  and configuration fingerprints before reuse; rebuild affected heads, preserve
  diagnostics for reused heads. Phase 4c extends publication to individual
  complete head analyses as they become ready.
- Avoid recursively hashing unrelated dependency trees. Reduce BIF location
  storage to declaration positions. Expose heads, graph edges, and refresh reuse
  counts in `nimdex/debug`.
- Share immutable Nim-owned declaration payloads across heads and actors using
  atomic ARC. Binny cursors/pools still stay inside one extraction worker.
- Canonicalize symlinked ancestors so compiler source paths and client URIs
  identify the same graph nodes, including files created after opening.
- Refresh on saves and watched-file events. Separate disk-generation stamps
  from document-buffer stamps so opening/typing during initial compilation
  cannot discard otherwise valid disk analysis.
- Test custom `srcDir`, package/directory name differences, test discovery,
  shared imports, includes, conditional imports, head variants, warm reuse,
  configuration/source invalidation, and failed refresh preservation.

The local compiler revision `8f1a8f6` hashes absolute module paths for suffixes
(`compiler/icmodnames.nim`), emits resolved import suffixes and include paths
(`compiler/ast2nif.nim`), and preserves byte-identical BIF mtimes. Neither a
matching suffix nor a matching filename proves configuration compatibility.
This phase reuses owned analyses; sharing frontend compilation across heads
through `nim ic` requires separate compatibility work. Arbitrary compile-time
file reads remain follow-up work; unsaved-buffer overlays are implemented in Phase 5. Phase 4c also
invalidates persisted analyses when the compiler environment changes.
Unknown client-reported disk changes conservatively invalidate all heads.

Verification: real compiler fixtures cover distinct src/test configurations,
`isMainModule` variants, resolved conditional imports, includes, and source
changes. A four-head fixture reuses all four heads on a warm refresh (zero
compiler commands and zero BIF loads), rebuilds one head for a private
dependency edit, and rebuilds three for a shared include edit. LSP tests cover
save notifications, new/deleted test heads, graph introspection, deduplicated
document symbols, and preservation of the last valid snapshot after failure.
The final end-to-end stdio run on this repository (13 heads)
parsed 608 BIF artifacts and reused 1,215: approximately 48.3 seconds cold and
0.49 seconds on an unchanged save, with zero warm compiler commands/BIF loads.
These are local observations, not timing assertions. The same run verifies
opening a document while initial compilation is still running.
All 12 test files pass with `atlas-run tests --nim=deps/nim-devel/bin/nim`,
and the release CLI builds with the same compiler.

Large graph reports exceeded Sigils' generic 1 MiB frame limit. Nimdex now
uses 16 MiB consistently in the server and CLI, and converts oversized outbound
responses into correlated errors before framing. CI now provisions the pinned
BIF-capable compiler and uses `atlas-run tests` with that compiler; its hosted
bootstrap still needs validation by GitHub Actions.

### Phase 4c: faster startup and shared frontend work

Priorities after project graph tracking:

1. Schedule the active document's actual head first, load other heads on
   demand/background, and publish successful head analyses progressively.
   Preserve healthy head results when a different head fails.
2. Persist validated graph and semantic records across server restarts. Keep
   compiler/configuration/source fingerprints and select a preferred actual
   head for each document, with an explicit override for ambiguous contexts.
3. Integrate per-head incremental compilation through the existing `nim track`
   frontend, then validate sharing its artifacts across compatible heads.
   Evaluate synthetic import batches separately; they change head semantics.

Items 1 and 2 are implemented in the current tree:

- Compiler refreshes emit complete per-head results. Failed heads no longer
  abort unrelated work. Only independently validated contexts are exposed;
  stale failed contexts are unavailable instead of being merged with healthy
  results. Source/configuration/compiler stamps still reject obsolete work.
- Document opens and symbol/hover requests prioritize pending heads through an
  atomic index into the refresh's fixed head list. A running head finishes
  normally. Known graph ownership selects the context; before discovery,
  the nearest head directory is only a scheduling hint. Other heads load in
  the background. Workspace queries and CLI checks wait for all heads.
- Versioned per-head manifests persist input fingerprints, diagnostics, and
  references to content-addressed owned module records. Atomic writes publish
  manifests after all records. Restoring rebuilds lookup tables and graph edges
  without invoking Nim or parsing BIFs. Damaged, missing, or incompatible
  records are cache misses. Live sessions retain their existing memory reuse.
- Validation includes compiler executable metadata, configuration/arguments,
  resolved sources/includes, source inventory, and an environment digest (no
  environment values are persisted). Track missing user/system and per-head
  `.nimcfg`/`.nim.cfg` files too, so creating a config invalidates reuse.
- `initializationOptions.preferredHeads` maps source paths to actual heads.
  A selected failed context is unavailable; it does not fall back to a different
  configuration. Default selection is the file's own head or its first resolved
  owner in path order. Debug output exposes choices, progress, and disk restores.

Verification covers persistent graph/symbol round trips, absent BIF files,
source invalidation, corrupt records/manifests, schema mismatches, dynamically
reprioritized heads, failure isolation, and explicitly selected test contexts.
Cache eviction and tracking arbitrary compile-time file reads remain open.

Real stdio measurements on this repository with 14 heads and the local release
daemon (2026-09-25):

| Run | First document symbols | All heads ready | Compiler calls | BIF loads |
| --- | ---: | ---: | ---: | ---: |
| Empty cache | 5.35 s | 53.15 s | 14 | 633 |
| New daemon, persisted cache | 0.78 s | 4.36 s | 0 | 0 |
| Unchanged save in that daemon | — | 0.54 s | 0 | 0 |

These are local observations, not timing assertions. The 14-head run adds the
cache test to the earlier 13-head baseline. A separate stdio probe deliberately
held a background compiler head waiting: the selected head returned symbols
before that head was released, and remained available after the released head
failed. An interactive CLI/stdio regression also checks healthy queries and
failed-head diagnostics without disconnecting the client early.
All 13 test files pass with `atlas-run tests --nim=deps/nim-devel/bin/nim`,
and the release daemon builds with that compiler.

#### Incremental frontend: per-head reuse, implemented as opt-in

Select this mode with CLI `--frontend track`, daemon `--frontend track`, or
`initializationOptions.compilerFrontend = "track"`. The default remains
`compile`. `src/nimdex/incremental.nim` reads the compiler's current build rules
to map source paths to artifacts, then traverses safely loaded `.s.deps.bif`
sidecars from the actual head and system root. This avoids reproducing the
compiler's module suffix hashing. Loaded config sources come from the IC
configuration artifact, since replayed configuration can omit ordinary hints.

Each head keeps compiler files under its own `frontend/` directory, alongside
Nimdex-owned captures and manifests. Source/configuration/environment validation
still gates publication. Configuration changes (including newly created config
files), source-inventory changes, and forced refreshes reset compiler state.
Ordinary source edits preserve it. Validated source timestamps are recorded in
owned locations when byte-identical BIFs retain older mtimes; unchanged symbol
payloads remain shared.

The existing local compiler provides a frontend-only entry through `nim track`:

```sh
deps/nim-devel/bin/nim track --nimcache:/path/to/head-cache tests/tfoo.nim
```

Without a definition/usages query, it still builds semantic artifacts and then
returns. `compiler/main.nim` invokes `commandIc(conf, frontendOnly = true)`;
`compiler/deps.nim` runs `nifler` and per-module `nim m` jobs through `nifmake`.
The backend is skipped, so this produces no C, native compilation, or linking.
`compiler/idetools.nim` returns without scanning for an IDE query when none was
requested. Nimdex can continue loading the resulting `.s.bif` files through
its existing safe Binny adapter and publishing owned semantic snapshots.

Manual probe with the local compiler revision `8f1a8f6` (2026-09-25): a head
imported one shared module containing an ordinary procedure. The head called
it inside `when isMainModule`. All three invocations succeeded without an IDE
query and produced zero C files:

| Operation | Elapsed | Semantic BIFs rewritten |
| --- | ---: | ---: |
| Empty compiler cache | 2.073 s | 28, including system modules |
| Unchanged invocation | 0.032 s | 0 |
| Shared procedure body edit | 0.091 s | 1, the shared module |

These are small-fixture observations, not whole-project benchmarks or proof of
semantic compatibility. BIF modification times established which artifacts
were rewritten; the full semantic compatibility suite is still required.

Implementation checklist (Nimdex scope):

- [x] Add an explicit frontend selection and capability probe for `track` plus
  compatible `nifler`/`nifmake`. Keep the current
  `c --compileOnly:on --genBif:on` path available; record the selected mode in
  cache identity and debug output. Missing tools, missing artifacts, and
  unsupported configurations need distinct errors from source compile errors.
- [x] Keep compiler state in a dedicated directory per compiler, configuration,
  mode, and actual head. The IC driver can delete its entire cache directory
  when `ic.version` changes, so persistent Nimdex manifests and semantic records
  must live outside that directory.
- [x] Preserve compiler artifacts across refreshes in incremental mode.
  `buildHead` only removes old BIFs in the default compilation mode.
  Preserve the existing validated whole-head memory/disk
  reuse so an unchanged save can still avoid invoking the compiler entirely.
- [x] Obtain the current resolved dependency closure after a successful build.
  Load only its semantic artifacts and reconcile graph ownership when imports
  change. A directory scan alone would retain orphan BIFs from earlier builds.
  Include implicit/system dependencies, includes, and discovered macro imports.
- [x] Preserve active-head priority, progressive publication, failure isolation,
  preferred contexts, source/configuration stamps, and fresh compiler errors.
  Verify required artifacts even after exit status zero: the driver can emit
  build instructions without executing them when `nifmake` is unavailable.
- [ ] Compare semantic output against the current frontend for declarations,
  locations, includes, overloads, generics, macros, conditional imports, cycles,
  duplicate module names, test configurations, and `isMainModule`. Treat mode
  differences such as `nimcheck` and the current `nim m` vtable behavior as
  compatibility gates; do not reuse records across modes by source path alone.
- [x] Add deterministic regressions for unchanged builds, body/interface edits,
  compile-time body dependencies, changed/removed imports, configuration changes,
  and recovery after failure. Assert semantic results and rebuild behavior;
  keep elapsed timings observational.
- [ ] Benchmark the repository's cold load, persisted restart, private edit,
  shared body edit, and shared interface edit. Report first-document latency,
  all-head completion, compiler/module work, BIF loads, and cache size separately.
- [ ] Provision and verify the matching compiler companions in CI before
  enabling this mode by default.

All 14 test files pass with
`atlas-run tests --nim=deps/nim-devel/bin/nim --only-errors`, and the release
daemon builds with the same compiler.
Fixtures verify source declarations/positions against `compile`, no C/native
outputs, per-module edge-cookie timestamps on body/interface edits, compile-time
body dependencies, macro-generated and implicit imports, includes, actual-head
and test-config variants, newly created config files, removed imports, corrupt
dependency metadata, restart restoration, and failed-build recovery. A real
stdio session uses `track` while checking healthy queries and failed-head
diagnostics. A comment-only edit preserves BIF mtimes while LSP symbols remain
available. Generated package/helper entries differ between frontends; parity
checks use the same source-token validation as LSP queries.

Remaining diagnostic gate: a manual probe confirms that `nim track` emits
warnings only for modules rechecked during that invocation. A warning in an
unchanged head disappears from compiler output after a body-only dependency
edit. Nimdex's whole-head reuse retains diagnostics, but a partial compiler
rebuild currently replaces them with that invocation's output. Persisting and
invalidating diagnostics per compilation unit, including include/generic
locations, needs a compiler-supported attribution scheme or a proven adapter
before making `track` the default. Do not assume that a silent skipped module
has become warning-free.

CI's pinned `koch boot` already builds the companion tools; the workflow now
checks that both executables exist. Hosted execution remains unverified.

Repository probe with the release daemon and 15 actual heads (2026-09-25):

| Run | First document symbols | Full refresh | Compiler calls | BIF loads |
| --- | ---: | ---: | ---: | ---: |
| Empty `track` cache | 6.97 s | 78.50 s | 15 | 211 |
| New daemon, persisted `track` cache | 0.95 s | 1.81 s | 0 | 0 |
| Unchanged save in that daemon | — | 0.33 s | 0 | 0 |

All heads succeeded. The cold refresh reused 1,973 identical artifacts while
extracting 211 unique module records; the cache occupied about 562 MiB with no
C files or native objects. The cold full-refresh duration comes from the
compiler worker's start/completion logs; restart/save durations are measured
through LSP. This is a 15-head checkout with additional implementation and tests,
so it is not a controlled comparison with the earlier 14-head baseline. No
cold-start speedup is established. The edit regressions prove skipped module
work; a repository-scale edit benchmark and cross-head compiler reuse remain
follow-ups.

Completion criterion: the existing language and compiler fixtures pass using
the incremental frontend; edits rebuild the expected module closure, removed
imports leave no stale symbols, and no C/backend work occurs. The first useful
integration requires no compiler embedding or replacement LSP query engine.
Compiler fixes should address demonstrated compatibility failures. A dedicated
frontend-only CLI switch would be an optional upstream improvement; bare
`nim track` already provides the tested entry point.

#### Then validate compiler artifact sharing across actual heads

Per-head incremental caches speed subsequent edits but can still check a shared
dependency once for each test on a cold load. Artifact sharing between heads
is a separate optimization from the identical-content semantic record sharing
already implemented in Nimdex.

`compiler/deps.nim:configSignatureFile` explicitly supports prefilling caches:
its signature excludes per-build project/config-artifact paths and hashes the
precompiled configuration without the cache-directory entry. This is useful
supporting machinery, not proof that arbitrary heads can exchange artifacts.

- [ ] Begin with separate writable head caches seeded from a validated pool of
  compatible module artifacts. Preserve actual-head identity and keep modules
  compiled as entry points distinct from the same modules compiled as imports.
- [ ] Define compatibility over compiler/artifact versions, frontend mode,
  effective configuration, defines, search paths, source/include inputs,
  dependency identities, and relevant environment/compile-time inputs. A shared
  path or module suffix alone is insufficient.
- [ ] Determine the complete reusable artifact bundle: parsed and semantic
  files, dependency metadata, interface/implementation cookies, and grouped
  cycle outputs. Preserve the build system's validity information and prevent
  one head's build from mutating artifacts owned by another active build.
- [ ] Test two heads with common imports, a head imported by another head,
  configuration differences, macros/static evaluation, and interface versus
  implementation changes. Prove equivalence against isolated compilation and
  measure whether the second head actually skips shared module work.
- [ ] Rebuild in isolation when compatibility cannot be established. If the
  current compiler lacks a required validity signal or produces incompatible
  identities, record a focused compiler change with a reproducing fixture
  before expanding reuse.

Completion criterion: compatible tests reuse frontend work while retaining
their own main-module semantics and diagnostics; incompatible tests remain
isolated. Do not replace this gate with a shared writable cache for all heads.

#### Alternative frontend: repair `nim check` BIF output

Semantic-only analysis experiment (2026-09-25): the pinned local compiler emits
`.s.bif` files with `nim check --genBif:on`, but the artifacts omit ordinary
declarations and include metadata. Existing indexing/LSP tests and a new
macro/generic fixture caught the omissions. In `compiler/pipelines.nim`,
`processPipeline` returns `graph.emptyNode` for `SemPass` unless the command is
`cmdM`; `--genBif` does not preserve the checked statement tree there.

Keep `nim c --compileOnly:on --genBif:on` as the default until a replacement
passes our semantic compatibility tests. This already skips native
compilation/linking, while still generating C. The preferred next experiment
is the existing incremental `track` frontend described above.

For a future `check` mode, fix the compiler to preserve `semNode` when semantic
serialization is requested, rebuild/pin the toolchain, and run declaration,
include, macro/generic, and location tests. This requires compiler work; it is
independent of the initial Nimdex-only `track` integration. `check` also defines
`nimcheck`, which must be treated as a distinct analysis context in persistent
cache identity. Compile-time macros and static evaluation still execute.

#### Optional experiment: synthetic import batches

Synthetic import experiment with the same compiler:

```nim
from tests/tfoo import nil
from tests/tbar import nil
```

`import tests/tfoo as nil` is rejected because aliases must be identifiers.
The valid form avoids bringing each module's members into unqualified scope;
aliases can disambiguate duplicate module names. A shared dependency was
checked once in the aggregate invocation. However, both imported heads saw
`isMainModule == false`. A root aggregate also omitted `tests/config.nims`;
placing the aggregate under `tests/` picked up that directory's configuration,
but cannot reproduce distinct per-head configuration files.

Use any future synthetic batches only for provisional background indexing,
grouped by effective configuration and guided by the resolved import graph.
Track batch provenance separately from actual heads and obtain a separate
analysis for the active real head. Do not discard actual heads just because
another head imports them. Account for import order and shared compile-time
state, and split/fall back to individual heads on errors. Verify macros,
generics, configuration differences, `isMainModule`, and diagnostic ownership
before claiming equivalence or measuring a startup improvement.

#### Remaining cache and project-loading work

- [ ] Persist a small ownership manifest that maps source/include paths to
  actual heads without loading every symbol record. Validate it before treating
  ownership as authoritative; stale metadata may only suggest scheduling order.
- [ ] Use that metadata to restore the active context first on daemon restart,
  then load other semantic records in the background while preserving complete
  workspace-query behavior.
- [ ] Add a size/age policy for compiler caches and unreferenced semantic
  records. Eviction must respect active refreshes, published manifests, and
  shared records, with interrupted cleanup handled as a recoverable cache miss.
- [ ] Investigate compiler-reported dependencies for arbitrary compile-time
  file reads and import-resolution changes outside the workspace. The current
  source/configuration/environment fingerprints do not cover every external
  file read by macros, `staticRead`, or static evaluation.

### Phase 5: unsaved-buffer analysis and richer features

#### Compiler cancellation and unsaved buffers

- [x] Supervise the compiler with cancellation checkpoints, a five-minute
  deadline, and bounded stdout/stderr captures. POSIX process groups terminate
  and reap the driver; a real `staticExec` child cancellation test passes on
  macOS. The Windows path uses `taskkill /T /F`; test it in Windows CI.
- [x] Verify repeated `--trackDirty` mappings with the pinned compiler for heads,
  imports and includes. Use a separate cache and `c --compileOnly:on` for dirty
  analyses, retaining original source/configuration paths without modifying
  workspace files. Commas in mapped paths are an explicit compiler limitation.
- [x] Retain version-ordered open buffers on the protocol side and language
  actor. Coalesce edits for 200 ms, stamp compiler work by source generation,
  and reject superseded results. Out-of-order notifications cannot replace
  current text. Clear obsolete pending-head diagnostics before new publication.
- [x] Include dirty content fingerprints in per-head reuse and source identity.
  Never persist dirty analyses as saved manifests. Retain at most one saved
  analysis per actual head alongside the current analysis for close/revert reuse.
- [x] Convert diagnostics against the checked open buffer and publish its version.
  The soak exercises invalid edits, recovery, close/reopen and many edit bursts.
- [ ] Verify Windows process-tree cancellation and broaden Unicode/CRLF dirty
  diagnostic fixtures, including shutdown while the compiler is blocked.

#### Occurrences, definitions, and static effects

- [x] Extract local declarations and true symbol kinds through safe Binny loading.
  Anonymous `td` compiler records are used while decoding effects, then discarded
  instead of retaining them as non-source symbols.
- [x] Load owned occurrences on demand into a four-entry cache keyed by artifact
  hash and source URI. Verify BIF content before/after loading, and release cache
  entries on document close or index replacement. Preserve selected-head context
  and distinguish module-local identities. Traversal has a 100,000-use bound.
- [x] Implement and advertise `textDocument/definition`. Real compiler tests cover
  imports, overloads, shadowed locals, generic instances, includes, UTF-16,
  style-insensitive identifiers, quoted operators, and stale/dirty buffers.
  Inline generic callees use verified call-site tokens; speculative name lookup
  is never substituted for compiler identity.
- [x] Show explicit and inferred static `raises` lists for procedures, including
  use-site hovers. Resolve inferred exception type identities through named
  type declarations. Distinguish a proven empty list from unavailable effects.
- [ ] Add references with context-aware deduplication and completeness while
  heads are pending/failed. Broaden macro-generated and multiline generic
  position coverage, and revisit occurrence limits for huge generated modules.

#### Lifetime and memory work

- [x] Release joined Sigils workers, their actors, channels, locks, and scheduler
  state. Defer thread deallocation until callback-held proxies have unwound;
  a proxy destructor can still send a release message to its scheduler.
- [x] Share immutable lookup indexes with copy-on-write when adding another head;
  a regression proves published readers retain their original indexes. Drop
  duplicate indexes from retained per-head snapshots, and clear progressive
  retention when the final snapshot is installed.
- [x] Fix Binny's `TokenBuf` destructor to release managed pools and construction
  state. A repeated safe-load probe and allocation stacks identified this leak.
  Dependency lifetime tests cover both immediate destruction and cursors that
  outlive the buffer; safe-loader and module suites also pass.
- [x] Limit default concurrent BIF loaders to four. Explicit indexing options
  can still select a different count; Atlas test job settings are unchanged.
- [x] Add `tools/profile_lsp.py` for repeatable unique revisions, edit bursts,
  failed edits, navigation/effects queries, close/reopen, RSS and shutdown.
- [ ] Add resident-head and persistent-cache eviction; full semantic heads are
  still retained. Extend short local soak evidence to hours on supported hosts.

### Long-running-session measurements

Measurements use release builds, atomic ARC, macOS arm64 and the pinned
`deps/nim-devel/` compiler. RSS includes allocator reserves and should not be
confused with live semantic payload. Compiler children are measured separately.

| Probe | Result |
| --- | --- |
| Existing server, 15 repository heads and 20 unchanged saves | RSS 776.6 → 798.2 MiB |
| Updated server, same 15 heads and 20 unchanged saves | RSS 230.6 → 256.5 MiB; plateau after three saves |
| Updated server, 100 edit/close/reopen cycles | Final RSS 127.2 MiB; sampled peak 130.6 MiB |
| Compiler process tree during that 100-cycle soak | Sampled peak 135.0 MiB, measured separately |

The repository comparison indexes 212 unique modules after the changes (211
before), about 68% less steady daemon RSS in this local run. The edit fixture
uses unique procedure names, eight buffer changes per cycle, definition/raises
queries, and an invalid edit every ten cycles. All 100 cycles, recovery checks,
and shutdown completed. These are short local samples, not an hours-long or
cross-platform stability claim. Timing overlapped other machine activity: the
updated cold repository load took 136.9 s with the first document at 9.4 s;
this run does not establish a cold-compilation speedup.

Validation: 16 Nimdex test executables; three focused Binny lifetime/safe-loader
executables; explicit real child-process cancellation; targeted navigation and
snapshot-sharing regressions; `git diff --check`. All use `deps/nim-devel/`.

Document highlights, completion, richer hover signatures, rename, and other
features remain follow-ups requiring their own verified scope/range semantics.

## API and ownership rules

Use named Nimdex value objects such as `DocumentSnapshot`, `AnalysisStamp`, `SymbolInfo`, `Occurrence`, `SourceLocation`, and `AnalysisFailure`. Distinguish:

- no matching symbol;
- analysis unavailable because artifacts/tooling are missing;
- cancellation or supersession;
- malformed/incompatible artifact;
- compiler failure;
- internal worker failure.

Use `sink` only where ownership is intentionally transferred, and verify that Sigils message construction does not retain aliases into worker-owned data. Expose copied strings and sequences at the language boundary. Keep LSP JSON conversion at the outer layer.

Document changes must be version-ordered. The current implementation accepts
full document synchronization and rejects ranged changes. Preserve that
validation until incremental text synchronization is explicitly implemented.

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
- Can the compiler's incremental frontend safely share compilation across
  heads while preserving configuration and main-module semantics?
- How should persistent analysis caching validate arbitrary compile-time file
  reads and changed import resolution outside the workspace beyond the current
  source/configuration fingerprints and environment digest?
- How will compiler overlays preserve import/configuration semantics for unsaved buffers?
- Which LSP capabilities can be backed by declaration positions before exact ranges and reference resolution are available?
