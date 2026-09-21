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
modules, source mappings, pool counts, and token counts.

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

The client should send the project `rootUri` in `initialize`. For explicit
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

Nimdex currently provides document symbols, workspace symbols, hover, full
document synchronization, and compiler diagnostics. Unsaved changes are
synchronized, but position-sensitive semantic results remain unavailable
until a matching compiler snapshot exists.

## How it works

Nimdex probes the configured compiler and requires `--genBif:on`. The daemon
runs a controlled compile into a project/configuration/source-specific cache,
safely loads the generated BIF files through Binny, and converts them into
owned semantic records. BIF loading and indexing use Sigils worker pools; the
blocking compiler process runs outside those workers.

The LSP publishes a complete stamped snapshot only after refresh succeeds,
preserving the last valid snapshot when a later build fails or is cancelled.
The CLI uses the same protocol messages as an editor rather than calling the
compiler or indexer through a separate shortcut.

Nimdex uses the generic LSP/JSON-RPC protocol and does not depend on the
`deps/langserver/` language backend or `nimsuggest`.

## Development

Run the full test suite with:

```sh
atlas-run tests
```
