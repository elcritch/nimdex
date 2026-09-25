import std/[os, unittest]

import nimdex/[documents, projectlayout, workspace, compiler]

suite "Nim project layout discovery":
  test "uses package srcDir and binaries and discovers only default tests":
    let root =
      normalizeDocumentPath(getTempDir() / ("nimdex-layout-" & $getCurrentProcessId()))
    createDir(root / "library")
    createDir(root / "tests" / "nested")
    defer:
      removeDir(root)
    writeFile(
      root / "package.nimble",
      """
srcDir = "library" # source directory
bin = @[
  "tool",
]
""",
    )
    for path in [
      "library/package.nim", "library/tool.nim", "tests/talpha.nim", "tests/tbeta.nim",
      "tests/helper.nim", "tests/nested/tnested.nim",
    ]:
      writeFile(root / path, "discard\n")
    let layout = discoverProjectLayout(root)
    check layout.heads ==
      @[
        root / "library/package.nim",
        root / "library/tool.nim",
        root / "tests/talpha.nim",
        root / "tests/tbeta.nim",
      ]
    check layout.sourceDirs == @[root / "library"]
    check layout.warnings.len == 0
    let workspace = initWorkspace(documentUriFromPath(root))
    check workspace.importPaths == layout.sourceDirs
    check workspace.discoverCompilerEntryPoints() == layout.heads
    let explicit = initWorkspace(
      documentUriFromPath(root), entryPoints = @[root / "library/tool.nim"]
    )
    check explicit.discoverCompilerEntryPoints() == @[root / "library/tool.nim"]

  test "reports computed metadata without executing it":
    let root = getTempDir() / ("nimdex-dynamic-layout-" & $getCurrentProcessId())
    createDir(root)
    defer:
      removeDir(root)
    writeFile(
      root / "package.nimble", "srcDir = getEnv(\"SRC\")\nbin = makeBinaries()\n"
    )
    let layout = discoverProjectLayout(root)
    check layout.warnings.len == 2
    check layout.heads.len == 0
    writeFile(root / "package.nimble", "when defined(windows):\n  srcDir = \"win\"\n")
    check discoverProjectLayout(root).warnings.len == 1

  test "discovers this repository's library, binary, and tests":
    let root = currentSourcePath.parentDir.parentDir
    let layout = discoverProjectLayout(root)
    check root / "src/nimdex.nim" in layout.heads
    check root / "tests/tcompiler.nim" in layout.heads
    check root / "tests/fixtures/binny_phase0/main.nim" notin layout.heads
