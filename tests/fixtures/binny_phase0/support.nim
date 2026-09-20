type ImportedRecord* = object
  name*: string

proc importedValue*(): ImportedRecord =
  ImportedRecord(name: "imported")
