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

Useful options are:

```text
--compiler PATH       Select the Nim compiler
--cache-root PATH     Store generated artifacts in PATH
--entry-point PATH    Add a Nim entry point (repeatable)
--import-path PATH    Add a Nim import path (repeatable)
--artifact-root PATH  Read existing BIF artifacts (repeatable)
--nim-arg ARG         Pass a controlled argument to Nim (repeatable)
--query TEXT          Filter symbols by name
--debug               Include the detailed daemon report with symbols
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

Nimdex currently provides document symbols, workspace symbols, hover, full
document synchronization, and compiler diagnostics. Unsaved changes are
synchronized, but position-sensitive semantic results remain unavailable
until a matching compiler snapshot exists.
Saving a document triggers analysis of disk contents. The server also accepts
`workspace/didChangeWatchedFiles` for source, test, and configuration changes.
Typing updates the buffer without repeatedly compiling unchanged disk files.

## How it works

Nimdex probes the configured compiler and requires `--genBif:on`. The daemon
runs `nim c --compileOnly:on --genBif:on` into a separate cache for each compiler,
configuration, and entry point. This generates C and semantic BIFs but skips
native compilation and linking. The current compiler's `nim check --genBif:on`
omits declarations and include metadata, so it cannot yet replace this command.
The daemon safely loads the generated BIF files through Binny and converts them into
owned semantic records. BIF loading and indexing use Sigils worker pools; the
blocking compiler process runs outside those workers.

Resolved BIF imports and includes form the module graph. A module can belong
to several actual heads, including a library compiled on its own and the tests
that import it. Identical BIFs share immutable declaration records; different
configurations and `isMainModule` branches retain their own variants.

Opening a document or querying its symbols/hover prioritizes its head after
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

The CLI uses the same protocol messages as an editor rather than calling the
compiler or indexer through a separate shortcut.

Nimdex uses the generic LSP/JSON-RPC protocol and does not depend on the
`deps/langserver/` language backend or `nimsuggest`.

## Development

Run the full test suite with:

```sh
atlas-run tests --nim=deps/nim-devel/bin/nim
```
