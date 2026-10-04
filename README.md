# Nimdex

Nimdex provides compiler-backed symbol indexing for Nim projects through a
small command-line client and an LSP server.

## Requirements

Nimdex defaults to `nim ic` and needs a Nim compiler that supports `--genBif:on`,
with matching `nifler` and `nifmake` companions beside Nim or on `PATH`. This
checkout includes them at `deps/nim-devel/bin/`; another environment must provide
an equivalent compiler and companions.

Install the `nimdex` command with Nimble:

```sh
nimble install https://github.com/elcritch/nimdex
nimdex version
```

Ensure Nimble's binary directory (usually `~/.nimble/bin`) is on `PATH`.
The Nimble package installs the Nimdex executable and its library dependencies;
it does not install a BIF-capable Nim compiler. Pass one with `--compiler PATH`
if it is not the default `nim` on `PATH`.

For development from a checkout, install project dependencies with
`atlas install`. To install the current checkout as a command, run
`nimble install` from the repository root.

To build a local executable with the compiler included in this checkout:

```sh
deps/nim-devel/bin/nim c -d:release --out:nimdex.out src/nimdex.nim
./nimdex.out version
```

## Logging

Nimdex writes Chronicles text blocks to `stderr` with forced ANSI colors, even
when the stream is redirected. LSP/JSON-RPC output on `stdout` remains clean.
For a long-lived daemon, `--log-file PATH` appends stderr to a chosen file.
Nimdex creates missing parent directories. A relative path uses the daemon's
working directory; the option works with stdio, `--listen`, and `--lsp-listen`
daemons.
For example, set Kosmo's `nimLspCommand` to:

```text
/absolute/path/to/nimdex daemon --compiler /absolute/path/to/nim --log-file /absolute/path/to/nimdex.log
```

Restart the editor after changing its command. The log file retains ANSI color
codes; omit `--log-file` to keep logs on stderr.

Debug builds include debug-level details; release builds default to info-level
summaries. BIF lists show a few filenames and a total;
`cacheRunId` identifies their per-head cache subtree. The `debug` CLI command
retains full paths. Compile with `-d:chronicles_log_level=TRACE` to include
per-artifact and per-symbol indexing traces.

Compiler stdout and stderr are captured in each head's cache directory as
`<head>.nim-compile.log`; an info log gives the path, byte counts, and exit
code after a compile. The CLI captures its child daemon's
Chronicles output and forwarded compiler diagnostics in bounded temporary
`nimdex-cli-*.daemon.log` and `nimdex-cli-*.diagnostics.log` files. It logs the
paths instead of printing every diagnostic. Each capture keeps at most 8 MiB
in its current file and 8 MiB in a `.1` rotation. Editor LSP diagnostics are
still published normally.
The CLI relays concise compiler progress: a start message for each head with
its project directory and cache run ID, a running heartbeat every five seconds,
compiler completion with exit code and elapsed time, each completed head with
its completed/total count, and the compile log path.
Detailed compiler warnings stay in the per-head log.

When launched from a directory containing a `.nimble` file, Nimdex parses its
project layout at startup, before the editor sends `initialize`. It rechecks
the layout if the package or head directories change before initialization.

## Command line

Run the installed CLI:

```sh
nimdex check /path/to/project --compiler /path/to/bif-enabled/nim
nimdex symbols /path/to/project
nimdex symbols /path/to/project exportedRoutine
nimdex debug /path/to/project
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

Start a listening daemon in one terminal, from this repository root:

```sh
nimdex daemon . --listen 49152 --compiler deps/nim-devel/bin/nim
```

The daemon logs `Nimdex CLI listener ready` with
`address: 127.0.0.1:49152` on stderr when it is ready to accept CLI requests.
Ctrl-C, SIGTERM, SIGHUP, and SIGQUIT close the listener and child LSP session.
In another terminal, query the same project without
starting a new analysis process:

```sh
nimdex check . --connect 49152
nimdex symbols . --connect 49152 --query newCompilerCancellation
nimdex debug . --connect 49152 | jq '.moduleGraph.actualHeads'
nimdex stop --connect 49152
```

Set `--compiler`, `--frontend track`, `--entry-point`, and other analysis
options on `daemon` when starting it. Queries reuse that configuration and its
in-memory semantic index. `--entry-point tests/tnavigation.nim` limits the
initial analysis to one head; otherwise Nimdex discovers the package and
`tests/t*.nim` heads. The listener accepts connections only on loopback and
serves one project. Use a different port for another project. Passing
`--listen 0` chooses a free port and logs its address. The plain `daemon` command
still uses stdin/stdout LSP transport for editors.
Stopping and restarting the listener with the same project, compiler, frontend,
and cache root restores valid head analyses from disk. `nimdex debug . --connect
PORT | jq '.refresh | {compiledHeads, restoredHeads}'` shows whether the new
daemon reused them; source or configuration changes rebuild affected heads.
Without an explicit cache root, Nimdex asks the selected compiler for the
resolved `nimcache` of the workspace's first entry point and stores artifacts and
semantic records in its `nimdex/` subdirectory. This respects `nim.cfg`,
`config.nims`, and the configured Nim arguments. Compiler/workspace fingerprints
and per-head subdirectories keep analyses isolated; process IDs and launch
directories do not select new caches. Unsaved buffers use a separate `overlays/`
subdirectory and never replace the saved-source analyses.

Useful options are:

```text
--compiler PATH       Select the Nim compiler
--frontend MODE       ic (default), compile, or track
--cache-root PATH     Override the default nimcache/nimdex location
--log-file PATH       Append daemon stderr to PATH (daemon only)
--entry-point PATH    Add a Nim entry point (repeatable)
--import-path PATH    Add a Nim import path (repeatable)
--artifact-root PATH  Read existing BIF artifacts (repeatable)
--nim-arg ARG         Pass a controlled argument to Nim (repeatable)
--query TEXT          Filter symbols by name
--debug               Include the detailed daemon report with symbols
--listen PORT         Listen for CLI requests (daemon only)
--connect PORT        Query an existing listening daemon
--lsp-listen PORT     Listen for editor LSP connections (daemon only)
--lsp-host ADDRESS    LSP TCP bind address (default: 127.0.0.1)
```

## Editor integration

Start the daemon directly when an editor launches an LSP server:

```sh
nimdex daemon
nimdex daemon --log-file /absolute/path/to/nimdex.log
```

### Connect an editor over TCP

Start a persistent LSP listener:

```sh
nimdex daemon --lsp-listen 9257 --compiler /absolute/path/to/bif-enabled/nim
```

The listener uses standard LSP `Content-Length`/JSON-RPC framing and binds to
`127.0.0.1` by default. `--lsp-listen 0` selects a free port and logs its address.
It serves one editor session at a time. Each connection has its own workspace,
open buffers, and request state; `shutdown`/`exit` closes that connection and
leaves the listener running for the next editor connection. Ctrl-C or SIGTERM
stops the listener and cancels the active session.

For Neovim 0.11 or later, configure its
[TCP connector](https://neovim.io/doc/user/lsp/#vim.lsp.rpc.connect()):

```lua
vim.lsp.config('nimdex_tcp', {
  cmd = vim.lsp.rpc.connect('127.0.0.1', 9257),
  filetypes = { 'nim' },
  root_markers = { '.git', 'nim.cfg', 'config.nims' },
})
vim.lsp.enable('nimdex_tcp')
```

For an editor that launches an LSP executable, use a stdio-to-TCP bridge such
as `nc 127.0.0.1 9257` as its server command. For example, Kosmo's
`nimLspCommand` can be set to that command while the listener runs separately.

To connect through Tailscale, bind to the server's Tailscale IP with
`--lsp-host 100.x.y.z` and use that address in the editor or bridge. The transport
is raw TCP. The server must be able to access the file paths in the editor's
`rootUri` and document URIs; TCP does not map paths between different machines.

`--listen` selects the CLI query protocol and `--lsp-listen` selects editor LSP.
Choose one listener mode for each daemon process. The compiler, frontend,
cache-root, and log-file options also apply to the LSP TCP daemon. An editor's
initialization options can override the compiler and cache defaults.

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
  "cacheRoot": "nimcache/nimdex"
}
```

Explicit `entryPoints` override automatic discovery. Computed Nimble metadata
is reported in `nimdex/debug` under `workspace.discoveryWarnings`; configure
entry points and import paths explicitly for those projects.
Omit `cacheRoot` to use the compiler-resolved location. The stdio daemon's
`--cache-root PATH` option also selects an explicit location for editor sessions;
an initialization option overrides that command-line default. Relative cache
paths are resolved against the initialized workspace root.

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

Nimdex probes the configured compiler and requires `--genBif:on`. By default,
the CLI and editor server run `nim ic --compileOnly:on --genBif:on` into a
separate cache for each compiler, configuration, and entry point. This generates
C and semantic BIFs but skips native compilation and linking. The current
compiler's `nim check --genBif:on` omits declarations and include metadata, so it
cannot yet replace this command.

The optional incremental frontend uses `nim track` to check modules and emit
semantic BIFs without generating C or running the native toolchain:

```sh
nimdex check /path/to/project --frontend track
nimdex daemon --frontend track
```

`ic` and `track` use the same per-head incremental graph loader.
Both modes retain compiler state between edits and use separate cache contexts.

Use `--frontend compile` to select `nim c --compileOnly:on --genBif:on`, or
`--frontend track` to select `nim track`. Editors can set
`"compilerFrontend": "compile"`, `"track"`, or `"ic"` in
`initializationOptions`; omitting the option selects `ic`. `ic` and `track`
require the matching `nifler` and `nifmake` companions supplied with
`deps/nim-devel/`. Each actual head retains its own compiler cache: unchanged
modules are skipped, and dependency metadata decides
which importers need rechecking. Only the current resolved module closure is
indexed, so removed imports leave no stale symbols even though their old files
remain in the compiler cache. Compiler state is separate from Nimdex's
persistent semantic records. `compile`, `track`, and `ic` use distinct cache
contexts. Dirty-buffer analysis currently uses `c --compileOnly:on` in a
separate cache, even when saved-file analysis uses `track` or `ic`. Dirty
semantic records are never persisted as saved analyses. The compiler's
dirty-file option cannot represent
paths containing commas; these produce an analysis error.

`nimcheck` conditionals and the incremental compiler's method dispatch behavior
can differ from `nim c`; switch back with `--frontend compile` when needed.
After a partial rebuild, diagnostics currently reflect modules checked in that
invocation; warnings from skipped modules may disappear. Whole-head cache reuse
retains its saved diagnostics.
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
compiler environment, resolved source/include and configuration inputs,
and the local source inventory before restoring records. New manifests compare
file content, so an mtime-only change does not force compilation. Older manifests
are upgraded when their saved inputs still match. Valid restores run no compiler
and load no BIF files. Missing, incompatible, or damaged cache entries rebuild.
Cold compilation still runs once per head; sharing compiler frontend work
across heads remains future work.

Each successful head publishes a stamped snapshot. Failed heads report
diagnostics while healthy heads remain available; queries requiring a failed
context report analysis unavailable. Superseded or cancelled work cannot
publish over a newer source generation. Arbitrary compile-time file reads
are not inferred from BIFs; watched-file events for unknown inputs rebuild all
heads. Changes to tracked compiler environment variables invalidate reuse;
other variables read by compile-time code are not tracked automatically.

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
