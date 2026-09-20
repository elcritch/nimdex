# nimdex

GitHub template repository for Nim packages using Atlas for dependency
management and GitHub Actions for CI.

## Use This Template

1. Create a new repository with GitHub's "Use this template" button.
2. Clone the new repository locally.
3. Pick the Nim package name you want to publish, using letters, numbers, and
   underscores.
4. Run:

```sh
./scripts/rename_template.sh your_package_name
```

That updates the starter package/module/test filenames and rewrites the
remaining `nimdex` / `nimdex` references in the template files.

## Setup

```sh
atlas install
```

Atlas writes dependency paths to `nim.cfg` and installs dependencies under
`deps/`. Those files are intentionally ignored.

## JSON-RPC over stdio

Run the stdin/stdout server with:

```sh
nim r src/nimdex_stdio.nim
```

It uses Sigils' LSP-style `Content-Length` framing and currently exposes the
`nimdex.greet` method with a `name` parameter. Keep diagnostics on stderr;
stdout is reserved for JSON-RPC messages.

## LSP over stdio

Run the initial LSP server with:

```sh
nim r src/nimdex_lsp.nim
```

Nimdex requires a Nim compiler that advertises `--genBif:on` so it can build
semantic artifacts for language features. In this checkout the development
compiler is `deps/nim-devel/bin/nim`; an equivalent BIF-capable compiler is
required in other environments. Nimdex does not use the `deps/langserver/`
language backend or `nimsuggest`.

Without artifact configuration the server supports lifecycle messages and full
document synchronization, but does not advertise semantic features. Configure
the BIF roots in `initialize.initializationOptions`:

```json
{"artifactRoots":["/path/to/nimcache"]}
```

With roots configured, Nimdex builds an owned snapshot and advertises verified
`documentSymbol`, `workspace/symbol`, and declaration `hover` results. Stale
or unsaved source that differs from the indexed artifact is suppressed rather
than served by a language shim. Offline BIF loading and semantic extraction
use independent Sigils worker-pool actors for parallelism.

## Test

Run the full test suite:

```sh
nim test
```

Run a single test:

```sh
nim r tests/tyour_package_name.nim
```

## Layout

- `src/your_package_name.nim`: package module after renaming.
- `tests/tyour_package_name.nim`: unit tests after renaming.
- `config.nims`: shared Nim switches and the `nim test` task.
- `.github/workflows/ci.yml`: GitHub Actions CI.
- `scripts/rename_template.sh`: one-shot template bootstrap rename.
# nimdex
