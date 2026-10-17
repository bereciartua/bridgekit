import Foundation
import Testing
@testable import BridgeKitCore

@Suite("Tool contract")
struct ToolContractTests {
    static let json = #"""
    {
      "$comment": "dropped",
      "serverInstructions": "Use read_notes before write_note.",
      "$defs": {
        "$comment": "dropped too",
        "noteID": {"type": "string", "minLength": 1, "$comment": "and this"},
        "tags": {"type": "array", "items": {"$ref": "#/$defs/tag"}},
        "tag": {"type": "string", "maxLength": 32}
      },
      "tools": [
        {"name": "read_notes", "annotations": {"readOnlyHint": true},
         "inputSchema": {"type": "object", "properties": {"id": {"$ref": "#/$defs/noteID"}},
                         "additionalProperties": false}},
        {"name": "write_note", "annotations": {"readOnlyHint": false, "destructiveHint": true},
         "inputSchema": {"type": "object", "required": ["id"],
                         "properties": {"id": {"$ref": "#/$defs/noteID"}, "tags": {"$ref": "#/$defs/tags"},
                                        "kept": {"$ref": "#/$defs/missing"},
                                        "local": {"$ref": "#/$defs/own", "description": "not a lone $ref"}},
                         "$defs": {"own": {"type": "integer"}}}},
        {"name": "no_annotations", "inputSchema": {"type": "object"}},
        {"name": "hint_not_bool", "annotations": {"readOnlyHint": "yes"}},
        {"title": "no name is skipped"}
      ]
    }
    """#

    func contract() throws -> ToolContract {
        try ToolContract(json: Data(Self.json.utf8))
    }

    @Test("parses instructions and tools in contract order")
    func parses() throws {
        let contract = try contract()
        #expect(contract.serverInstructions == "Use read_notes before write_note.")
        #expect(contract.tools.map(\.name) == ["read_notes", "write_note", "no_annotations", "hint_not_bool"])
        #expect(contract.tool(named: "write_note")?.name == "write_note")
        #expect(contract.tool(named: "missing") == nil)
        #expect(contract.tool(named: "hint_not_bool")?.inputSchema.isEmpty == true)
        // No instructions is an empty string.
        let bare = try ToolContract(json: Data(#"{"tools": []}"#.utf8))
        #expect(bare.serverInstructions == "" && bare.tools.isEmpty)
    }

    @Test("refuses what isn't a contract")
    func refuses() {
        #expect(throws: ToolContract.Problem.notJSON) { try ToolContract(json: Data("{".utf8)) }
        #expect(throws: ToolContract.Problem.notJSON) { try ToolContract(json: Data("[]".utf8)) }
        #expect(throws: ToolContract.Problem.missingTools) { try ToolContract(json: Data("{}".utf8)) }
        #expect(throws: ToolContract.Problem.missingTools) {
            try ToolContract(json: Data(#"{"tools": {"a": 1}}"#.utf8))
        }
    }

    @Test("drops $comment everywhere")
    func dropsComments() throws {
        let contract = try contract()
        #expect(contract.document["$comment"] == nil)
        #expect((contract.document["$defs"] as? [String: Any])?["$comment"] == nil)
        let text = try canonical(contract.tools.map(\.definition))
        #expect(!text.contains("$comment"))
        #expect(!text.contains("and this"))
    }

    @Test("inlines shared $defs references, recursively")
    func inlines() throws {
        let contract = try contract()
        let read = try #require(contract.tool(named: "read_notes"))
        let id = read.inputSchema["properties"].flatMap { ($0 as? [String: Any])?["id"] } as? [String: Any]
        #expect(id?["type"] as? String == "string")
        #expect(id?["minLength"] as? Int == 1)
        #expect(id?["$comment"] == nil)
        let write = try #require(contract.tool(named: "write_note"))
        let properties = try #require(write.inputSchema["properties"] as? [String: Any])
        let tags = try #require(properties["tags"] as? [String: Any])
        // A fragment that refers to another fragment is inlined all the way.
        #expect(try canonical(tags) == #"{"items":{"maxLength":32,"type":"string"},"type":"array"}"#)
        // Unknown references, and objects with more than the $ref, stay as they are; so do a tool's own $defs.
        #expect(try canonical(properties["kept"] ?? [:]) == ##"{"$ref":"#/$defs/missing"}"##)
        #expect((properties["local"] as? [String: Any])?["$ref"] as? String == "#/$defs/own")
        #expect(write.inputSchema["$defs"] != nil)
        // The inlined schema validates.
        #expect(JSONSchemaValidator.validate(["id": "n1", "tags": ["a"]], against: write.inputSchema) == nil)
        #expect(JSONSchemaValidator.validate(["id": "", "tags": ["a"]], against: write.inputSchema)
                == "id: must not be empty")
        #expect(JSONSchemaValidator.validate(["id": "n", "tags": [String(repeating: "t", count: 33)]],
                                             against: write.inputSchema)
                == "tags[0]: must be at most 32 bytes of UTF-8, got 33")
        // The static helper works on any value.
        let inlined = ToolContract.inline([["$ref": "#/$defs/a"], 3], shared: ["a": ["const": 1]])
        #expect(try canonical(inlined) == #"[{"const":1},3]"#)
    }

    @Test("isWrite comes from annotations.readOnlyHint")
    func isWrite() throws {
        let contract = try contract()
        #expect(contract.tool(named: "read_notes")?.isWrite == false)
        #expect(contract.tool(named: "write_note")?.isWrite == true)
        // Anything not marked read-only is a write.
        #expect(contract.tool(named: "no_annotations")?.isWrite == true)
        #expect(contract.tool(named: "hint_not_bool")?.isWrite == true)
        #expect(ToolDefinition(name: "x", definition: ["annotations": ["readOnlyHint": true]]).isWrite == false)
        #expect(ToolDefinition(name: "x", definition: [:]).isWrite == true)
    }

    func canonical(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }
}
