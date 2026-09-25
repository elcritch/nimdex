## Owned module dependencies and their actual compiler entry points.

import std/[algorithm, sets, tables]

type
  ModuleDependencies* = object
    sourcePath*: string
    imports*: seq[string]
    includes*: seq[string]
    unresolvedImports*: seq[string]

  ModuleGraph* = object
    heads*: seq[string]
    modules*: Table[string, ModuleDependencies]
    importers*: Table[string, seq[string]]
    sourceHeads*: Table[string, seq[string]]

proc addUnique(values: var seq[string], value: string) =
  if value notin values:
    values.add(value)
    values.sort()

proc addHead*(
    graph: var ModuleGraph,
    head: string,
    modules: openArray[ModuleDependencies],
    compiledClosure = false,
) =
  ## Record one resolved compiler context. Union edges for navigation, but walk
  ## only this head's own graph when attributing ownership to sources.
  graph.heads.addUnique(head)
  var context = initTable[string, ModuleDependencies]()
  for module in modules:
    context[module.sourcePath] = module
    var merged = graph.modules.getOrDefault(module.sourcePath)
    merged.sourcePath = module.sourcePath
    for path in module.imports:
      merged.imports.addUnique(path)
      graph.importers.mgetOrPut(path, @[]).addUnique(module.sourcePath)
    for path in module.includes:
      merged.includes.addUnique(path)
      graph.importers.mgetOrPut(path, @[]).addUnique(module.sourcePath)
    for suffix in module.unresolvedImports:
      merged.unresolvedImports.addUnique(suffix)
    graph.modules[module.sourcePath] = merged

  var pending = @[head]
  if compiledClosure:
    # Fresh per-head compiler output also proves ownership of implicit modules
    # such as system, which need not have an explicit BIF import edge.
    for module in modules:
      pending.add(module.sourcePath)
  var seen = initHashSet[string]()
  while pending.len > 0:
    let path = pending.pop()
    if not seen.containsOrIncl(path):
      graph.sourceHeads.mgetOrPut(path, @[]).addUnique(head)
      if path in context:
        pending.add(context[path].imports)
        pending.add(context[path].includes)

proc headsFor*(graph: ModuleGraph, sourcePath: string): seq[string] =
  ## All actual compiler heads reaching this source, in deterministic order.
  graph.sourceHeads.getOrDefault(sourcePath)

proc preferredHead*(graph: ModuleGraph, sourcePath: string): string =
  ## A real head uses its own context. Other sources use a deterministic owner.
  if sourcePath in graph.heads:
    return sourcePath
  let owners = graph.headsFor(sourcePath)
  if owners.len > 0:
    return owners[0]

proc affectedHeads*(graph: ModuleGraph, changedPaths: openArray[string]): seq[string] =
  for path in changedPaths:
    for head in graph.headsFor(path):
      result.addUnique(head)
