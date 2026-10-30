import std/[json, options, os, strutils, tempfiles, unittest]

import nimdex/[documents, lsp]
import sigils/rpcs/jsonrpc

proc request(server: LspServer, message: JsonNode): JsonNode =
  let response = server.jsonRpcAdapter().handleJsonRpc($message)
  doAssert response.isSome()
  parseJson(response.get())

proc notify(server: LspServer, methodName: string, params: JsonNode) =
  discard server.jsonRpcAdapter().handleJsonRpc(
      $(%*{"jsonrpc": "2.0", "method": methodName, "params": params})
    )

suite "receiver completion":
  test "suggests matching callable receivers from BIFs in an incomplete buffer":
    let root = normalizeDocumentPath(createTempDir("nimdex-completion-", ""))
    defer:
      removeDir(root)
    let head = root / "main.nim"
    let library = root / "widgets.nim"
    writeFile(
      library,
      """
type Widget* = ref object of RootObj
  size*: int
  secret: int
type Fancy* = ref object of Widget
type Wrapper* = object
  member*: Widget
proc grow*(self: Widget): int = self.size
proc shrink*(self: var Widget) = discard
proc unrelated*(self: string) = discard
""",
    )
    let saved = """
import widgets
proc run() =
  var item: Widget
  discard item
  let fancy: Fancy = nil
  discard fancy
proc later() =
  discard 42
proc chain() =
  var wrapper: Wrapper
  discard wrapper
"""
    writeFile(head, saved)
    let server = newNimdexLspServer(compilerPath = findExe("nim"))
    defer:
      server.close()
    let initialized = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "rootUri": documentUriFromPath(root),
          "capabilities": {},
          "initializationOptions": {"entryPoints": [head], "importPaths": [root]},
        },
      }
    )
    require initialized.hasKey("result")
    check initialized["result"]["capabilities"]["completionProvider"][
      "triggerCharacters"
    ][0].getStr() == "."
    server.notify("initialized", %*{})
    let uri = documentUriFromPath(head)
    server.notify(
      "textDocument/didOpen",
      %*{"textDocument": {"uri": uri, "version": 1, "text": saved}},
    )
    let beforeEdit = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 80,
        "method": "nimdex/debug",
        "params": {"summaryOnly": true},
      }
    )["result"]
    let edited = saved.replace("discard item", "discard item.")
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": edited}]
      },
    )
    let afterEdit = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 81,
        "method": "nimdex/debug",
        "params": {"summaryOnly": true},
      }
    )["result"]
    check afterEdit["refresh"]["cachePath"] == beforeEdit["refresh"]["cachePath"]
    check afterEdit["semantic"]["sourceFingerprint"] ==
      beforeEdit["semantic"]["sourceFingerprint"]
    check not afterEdit["refresh"]["debouncing"].getBool()
    let completed = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 3, "character": 15}},
      }
    )
    checkpoint $completed
    require completed.hasKey("result")
    var labels: seq[string]
    for item in completed["result"]:
      labels.add(item["label"].getStr())
    check "grow" in labels
    check "size" in labels
    check "secret" notin labels
    for item in completed["result"]:
      if item["label"].getStr() == "size":
        check item["kind"].getInt() == 5
    check "shrink" in labels
    check "unrelated" notin labels
    let inherited = saved.replace("discard fancy", "discard fancy.")
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 3},
        "contentChanges": [{"text": inherited}],
      },
    )
    let inheritedResult = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 5, "character": 16}},
      }
    )
    checkpoint $inheritedResult
    require inheritedResult.hasKey("result")
    var inheritedLabels: seq[string]
    for item in inheritedResult["result"]:
      inheritedLabels.add(item["label"].getStr())
    check "grow" in inheritedLabels
    check "shrink" notin inheritedLabels
    let outOfScope = saved.replace("discard 42", "discard item.")
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 4},
        "contentChanges": [{"text": outOfScope}],
      },
    )
    let outOfScopeResult = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 4,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 7, "character": 15}},
      }
    )
    checkpoint $outOfScopeResult
    require outOfScopeResult.hasKey("result")
    check outOfScopeResult["result"].len == 0
    let changedDeclaration = saved
      .replace("var item: Widget", "var item: string")
      .replace("discard item", "discard item.")
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 5},
        "contentChanges": [{"text": changedDeclaration}],
      },
    )
    let staleResult = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 5,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 3, "character": 15}},
      }
    )
    checkpoint $staleResult
    require staleResult.hasKey("result")
    check staleResult["result"].len == 0
    let changedType = saved.replace("var item: Widget", "var item: Fancy")
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 6},
        "contentChanges": [{"text": changedType}],
      },
    )
    let changedTypeEdit = changedType.replace("discard item", "discard item.g")
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 7},
        "contentChanges": [{"text": changedTypeEdit}],
      },
    )
    let unsavedResult = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 6,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 3, "character": 16}},
      }
    )
    checkpoint $unsavedResult
    require unsavedResult.hasKey("result")
    var unsavedLabels: seq[string]
    for item in unsavedResult["result"]:
      unsavedLabels.add(item["label"].getStr())
    check unsavedLabels.len == 0
    writeFile(head, changedType)
    server.notify("textDocument/didSave", %*{"textDocument": {"uri": uri}})
    let savedTypeResult = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 60,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 3, "character": 16}},
      }
    )
    require savedTypeResult.hasKey("result")
    var savedLabels: seq[string]
    for item in savedTypeResult["result"]:
      savedLabels.add(item["label"].getStr())
    check "grow" in savedLabels
    check "shrink" notin savedLabels
    writeFile(head, saved)
    server.notify("textDocument/didSave", %*{"textDocument": {"uri": uri}})
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 8}, "contentChanges": [{"text": saved}]
      },
    )
    let styled = saved.replace("discard item", "discard i_te_m.g")
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 9}, "contentChanges": [{"text": styled}]
      },
    )
    let styledResult = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 7,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 3, "character": 18}},
      }
    )
    checkpoint $styledResult
    require styledResult.hasKey("result")
    var styledLabels: seq[string]
    for item in styledResult["result"]:
      styledLabels.add(item["label"].getStr())
    check "grow" in styledLabels
    let chained = saved.replace("discard wrapper", "discard wrapper.member.")
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 10},
        "contentChanges": [{"text": chained}],
      },
    )
    let chainedResult = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 8,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 10, "character": 25}},
      }
    )
    checkpoint $chainedResult
    require chainedResult.hasKey("result")
    var chainedLabels: seq[string]
    for item in chainedResult["result"]:
      chainedLabels.add(item["label"].getStr())
    check "grow" in chainedLabels

  test "completes private fields in an included source file":
    let root = normalizeDocumentPath(createTempDir("nimdex-completion-include-", ""))
    defer:
      removeDir(root)
    let
      head = root / "main.nim"
      includeFile = root / "piece.nim"
      saved = "proc layout(content: Content) =\n  discard content\n"
    writeFile(
      head,
      "type Content = ref object\n  splitView: int\n  setInitialDivider: bool\ninclude piece\n",
    )
    writeFile(includeFile, saved)
    let server = newNimdexLspServer(compilerPath = findExe("nim"))
    defer:
      server.close()
    let initialized = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "rootUri": documentUriFromPath(root),
          "capabilities": {},
          "initializationOptions": {"entryPoints": [head], "importPaths": [root]},
        },
      }
    )
    require initialized.hasKey("result")
    server.notify("initialized", %*{})
    let uri = documentUriFromPath(includeFile)
    server.notify(
      "textDocument/didOpen",
      %*{"textDocument": {"uri": uri, "version": 1, "text": saved}},
    )
    server.notify(
      "textDocument/didChange",
      %*{
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges":
          [{"text": saved.replace("discard content", "discard content.")}],
      },
    )
    let response = server.request(
      %*{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "textDocument/completion",
        "params":
          {"textDocument": {"uri": uri}, "position": {"line": 1, "character": 18}},
      }
    )
    checkpoint $response
    require response.hasKey("result")
    var labels: seq[string]
    for item in response["result"]:
      labels.add(item["label"].getStr())
    check "splitView" in labels
    check "setInitialDivider" in labels
