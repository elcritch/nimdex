# Nimdex

Nimdex provides compiler-backed symbol indexing for Nim projects through a
small command-line client and an LSP server.

## Requirements

Nimdex needs a Nim compiler that supports `--genBif:on`. This checkout
includes one at `deps/nim-devel/bin/nim`; another environment must provide an
equivalent compiler.

Install the project dependencies with Atlas:

```sh
atlas install
```

## Logging

Nimdex writes structured Chronicles logs to `stderr` so LSP/JSON-RPC output on
`stdout` remains clean. Debug builds include debug-level details; release builds
default to info-level summaries. Compile with
`-d:chronicles_log_level=TRACE` to include per-symbol indexing traces.

## Command line

Run the CLI directly from a checkout:

```sh
nim r src/nimdex.nim -- check /path/to/project
nim r src/nimdex.nim -- symbols /path/to/project
nim r src/nimdex.nim -- symbols /path/to/project exportedRoutine
nim r src/nimdex.nim -- debug /path/to/project
```

The project defaults to the current directory. The commands start a short-
lived Nimdex daemon, communicate with it using the same LSP
`Content-Length`/JSON-RPC transport used by editors, and then shut it down.

`check` reports whether a compiler-backed semantic snapshot was built.
`symbols` sends the standard `workspace/symbol` request and prints matching
declarations. `debug` sends the custom `nimdex/debug` request and prints the
compiler, workspace paths, refresh command/cache, generated BIF files, loaded
modules, source mappings, pool counts, and token counts. It also shows
`moduleGraph.actualHeads`, imports/includes, reverse importers, each source's
`headFiles`, and counts of compiled/reused heads and loaded/reused artifacts.

### Query a running daemon

Build once from this checkout:

```sh
deps/nim-devel/bin/nim c -d:release -o:/tmp/nimdex src/nimdex.nim
```

Start a listening daemon in one terminal, from this repository root:

```sh
/tmp/nimdex daemon . --listen 49152 --compiler deps/nim-devel/bin/nim
```

The daemon prints `nimdex listening on 127.0.0.1:49152` when it is ready to
accept CLI requests. In another terminal, query the same project without
starting a new analysis process:

```sh
/tmp/nimdex check . --connect 49152
/tmp/nimdex symbols . --connect 49152 --query newCompilerCancellation
/tmp/nimdex debug . --connect 49152 | jq '.moduleGraph.actualHeads'
/tmp/nimdex stop --connect 49152
```

Set `--compiler`, `--frontend track`, `--entry-point`, and other analysis
options on `daemon` when starting it. Queries reuse that configuration and its
in-memory semantic index. `--entry-point tests/tnavigation.nim` limits the
initial analysis to one head; otherwise Nimdex discovers the package and
`tests/t*.nim` heads. The listener accepts connections only on loopback and
serves one project. Use a different port for another project. Passing
`--listen 0` chooses a free port and prints it. The plain `daemon` command
still uses stdin/stdout LSP transport for editors.

Useful options are:

```text
--compiler PATH       Select the Nim compiler
--frontend MODE       compile (default) or track (incremental)
--cache-root PATH     Store generated artifacts in PATH
--entry-point PATH    Add a Nim entry point (repeatable)
--import-path PATH    Add a Nim import path (repeatable)
--artifact-root PATH  Read existing BIF artifacts (repeatable)
--nim-arg ARG         Pass a controlled argument to Nim (repeatable)
--query TEXT          Filter symbols by name
--debug               Include the detailed daemon report with symbols
--listen PORT         Listen for CLI requests (daemon only)
--connect PORT        Query an existing listening daemon
```

## Editor integration

Start the daemon directly when an editor launches an LSP server:

```sh
nim r src/nimdex.nim -- daemon
```

The client should send the project `rootUri` in `initialize`. Nimdex discovers
the package module and declared binaries using literal `srcDir` and `bin`
assignments in the root Nimble file, plus the default `tests/t*.nim` files.
Each test is a compiler entry point with its own configuration. Without a
Nimble file, discovery checks `src/` and root main/package modules.

For explicit
compiler configuration, put options such as these in
`initialize.initializationOptions`:

```json
{
  "compilerPath": "/path/to/nim",
  "entryPoints": ["main.nim"],
  "importPaths": ["src"],
  "cacheRoot": ".nimdex/nimcache"
}
```

Explicit `entryPoints` override automatic discovery. Computed Nimble metadata
is reported in `nimdex/debug` under `workspace.discoveryWarnings`; configure
entry points and import paths explicitly for those projects.

For a source used under different test configurations, select its context with
`"preferredHeads": {"src/shared.nim": "tests/tfeature.nim"}` in the same options.
Paths are relative to the workspace. The head must be discovered or explicitly
configured. Otherwise, a head uses its own context and shared sources use the
first resolved owner in path order.

Nimdex provides document symbols, workspace symbols, go to definition, hover,
full document synchronization, and compiler diagnostics. Procedure hovers show
compiler-derived static `raises` effects, including inferred exceptions and
`raises: []`. Missing effect information is shown as `raises: unknown`.

Edits are coalesced for 200 ms, then checked using Nim's dirty-file mappings.
Multiple open buffers and includes retain their original source paths; editor
text is never written over project files. Definitions and hover work on those
checked buffers. Results from superseded revisions are discarded, and diagnostic
notifications include the open document's version. Closing a buffer restores
analysis of disk contents. Saves and `workspace/didChangeWatchedFiles` also
trigger refreshes.

Definition lookup uses compiler symbol identities to distinguish overloads,
locals and generic instances within the selected actual head. Source ranges are
verified against current text, including UTF-16 positions and Nim identifier
spelling rules. Unverifiable generated locations return no target.

## How it works

Nimdex probes the configured compiler and requires `--genBif:on`. The daemon
runs `nim c --compileOnly:on --genBif:on` into a separate cache for each compiler,
configuration, and entry point. This generates C and semantic BIFs but skips
native compilation and linking. The current compiler's `nim check --genBif:on`
omits declarations and include metadata, so it cannot yet replace this command.

The optional incremental frontend uses `nim track` to check modules and emit
semantic BIFs without generating C or running the native toolchain:

```sh
nimdex check /path/to/project --frontend track
nimdex daemon --frontend track
```

Editors can select it with `"compilerFrontend": "track"` in
`initializationOptions`. It requires the matching `nifler` and `nifmake`
companions supplied with `deps/nim-devel/`. Each actual head retains its own
compiler cache: unchanged modules are skipped, and dependency metadata decides
which importers need rechecking. Only the current resolved module closure is
indexed, so removed imports leave no stale symbols even though their old files
remain in the compiler cache. Compiler state is separate from Nimdex's
persistent semantic records. `compile` and `track` use distinct cache contexts.
Dirty-buffer analysis currently uses `c --compileOnly:on` in a separate cache,
even when saved-file analysis uses `track`. Dirty semantic records are never
persisted as saved analyses. The compiler's dirty-file option cannot represent
paths containing commas; these produce an analysis error.

This mode is opt-in while broader compiler compatibility is evaluated.
`nimcheck` conditionals and the incremental compiler's method dispatch behavior
can differ from `nim c`; switch back with `--frontend compile` when needed.
After a partial rebuild, diagnostics currently reflect modules checked in that
invocation; warnings from skipped modules may disappear. Whole-head cache reuse
retains its saved diagnostics. Complete diagnostic persistence across partial
builds remains a gate before enabling this mode by default.
Configuration, environment, and source-inventory changes conservatively reset
the incremental compiler cache. Compilation work is still separate per head;
sharing those artifacts across heads is future work.

The daemon safely loads the generated BIF files through Binny and converts them into
owned semantic records. BIF loading and indexing use Sigils worker pools, with at most four loaders by
default to limit peak memory. Compiler processes run separately and are cancelled
when superseded. Each compiler command has a five-minute limit and an 8 MiB
capture limit per output stream.

Resolved BIF imports and includes form the module graph. A module can belong
to several actual heads, including a library compiled on its own and the tests
that import it. Identical BIFs share immutable declaration records; different
configurations and `isMainModule` branches retain their own variants.

Opening a document or querying its symbols/hover/definition prioritizes its head after
the currently running head. Before its graph is known, Nimdex uses the closest
head directory as a scheduling hint. Other heads load in the background.
Document queries can complete as soon as their context is ready; workspace
symbol queries and CLI project checks wait for the whole refresh.

Unchanged heads reuse their analyses and diagnostics. Owned semantic records
and per-head manifests also persist under the cache root, sharing identical
module records. Restarts validate compiler identity, compiler arguments,
environment, resolved source/include and configuration inputs, and the local
source inventory before restoring records. Valid restores run no compiler and
load no BIF files. Missing, incompatible, or damaged cache entries rebuild.
Cold compilation still runs once per head; sharing compiler frontend work
across heads remains future work.

Each successful head publishes a stamped snapshot. Failed heads report
diagnostics while healthy heads remain available; queries requiring a failed
context report analysis unavailable. Superseded or cancelled work cannot
publish over a newer source generation. Arbitrary compile-time file reads
are not inferred from BIFs; watched-file events for unknown inputs rebuild all
heads. Changing environment variables between sessions invalidates reuse.

`nimdex/debug` exposes pending/completed/failed heads, selected contexts, and
`restoredHeads` alongside compilation and BIF reuse counts. Its optional
`{"summaryOnly": true}` parameters omit module details for inexpensive polling.
It also reports `openBuffers`, `debouncing`, and `retiredWorkers`. The compiler
report includes the selected `frontend`, `supportsTrack`, and companion paths.

The server uses open/close notifications and recent queries to manage its working
set. A four-entry cache loads occurrences only for queried source files and drops
them on buffer close or snapshot replacement. Identical declarations and immutable
lookup indexes are shared; retained heads omit duplicate indexes.
Sigils is pinned to the revision used to verify scheduler teardown. Saved analyses
remain available while editing so closing buffers can reuse them. Binny is pinned
to a revision that fixes token-buffer pool lifetime under ARC/atomic ARC.

For a repeatable edit/close/reopen memory probe, build a release daemon and run:

```sh
deps/nim-devel/bin/nim c -d:release --out:/tmp/nimdex src/nimdex.nim
python3 tools/profile_lsp.py --server /tmp/nimdex --cycles 100
```

The probe emits JSONL with daemon RSS, sampled compiler-tree RSS and cycle time.
It also checks navigation, static effects, versioned diagnostics and clean shutdown.
Use `--saved` for comparisons with older servers; use `--keep` to retain logs.
See [the plan](PLAN.md#long-running-session-measurements) for measured results and
remaining long-session work.

The CLI uses the same protocol messages as an editor rather than calling the
compiler or indexer through a separate shortcut.

Nimdex uses the generic LSP/JSON-RPC protocol and does not depend on the
`deps/langserver/` language backend or `nimsuggest`.

## Development

Run the full test suite with:

```sh
atlas-run tests --nim=deps/nim-devel/bin/nim
```
