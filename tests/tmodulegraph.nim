import std/[tables, unittest]

import nimdex/modulegraph

suite "Actual compiler heads":
  test "keeps imported heads and tracks transitive includes through cycles":
    var graph: ModuleGraph
    let modules =
      @[
        ModuleDependencies(sourcePath: "app", imports: @["library"]),
        ModuleDependencies(sourcePath: "library", imports: @["shared"]),
        ModuleDependencies(
          sourcePath: "shared", imports: @["library"], includes: @["part"]
        ),
      ]
    graph.addHead("app", modules)
    graph.addHead("library", modules)
    check graph.heads == @["app", "library"]
    check graph.headsFor("part") == @["app", "library"]
    check graph.affectedHeads(["shared", "part"]) == @["app", "library"]
    check graph.importers["library"] == @["app", "shared"]

  test "does not attribute conditional edges from another head":
    var graph: ModuleGraph
    graph.addHead(
      "a",
      [
        ModuleDependencies(sourcePath: "a", imports: @["shared"]),
        ModuleDependencies(sourcePath: "shared", imports: @["onlyA"]),
      ],
    )
    graph.addHead(
      "b",
      [
        ModuleDependencies(sourcePath: "b", imports: @["shared"]),
        ModuleDependencies(sourcePath: "shared", imports: @["onlyB"]),
      ],
    )
    check graph.headsFor("onlyA") == @["a"]
    check graph.headsFor("onlyB") == @["b"]
    check graph.headsFor("shared") == @["a", "b"]
    check graph.headsFor("unknown").len == 0
