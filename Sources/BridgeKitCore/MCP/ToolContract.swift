import Foundation

/// An app's tool contract: server instructions and tools, as one JSON
/// document (EK Bridge's and Funes's `tools.json`). Shared `$defs` fragments
/// are inlined into each tool's definition; `$comment` keys are dropped.
public struct ToolContract: @unchecked Sendable {
    public enum Problem: Error, Equatable, Sendable {
        case notJSON
        case missingTools
    }

    public let serverInstructions: String
    /// In contract order, which is also `tools/list` order.
    public let tools: [ToolDefinition]
    /// The parsed document, `$comment` keys removed.
    public let document: [String: Any]

    public init(json data: Data) throws(Problem) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .notJSON
        }
        let document = Self.removingComments(object) as? [String: Any] ?? object
        guard let raw = document["tools"] as? [[String: Any]] else { throw .missingTools }
        let shared = document["$defs"] as? [String: Any] ?? [:]
        serverInstructions = document["serverInstructions"] as? String ?? ""
        tools = raw.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            return ToolDefinition(name: name, definition: Self.inline(tool, shared: shared) as? [String: Any] ?? tool)
        }
        self.document = document
    }

    public func tool(named name: String) -> ToolDefinition? {
        tools.first { $0.name == name }
    }

    /// Replaces each `{"$ref": "#/$defs/<shared>"}` with the shared fragment.
    /// A tool's own `$defs` (list_collections' output) stay as they are.
    public static func inline(_ value: Any, shared: [String: Any]) -> Any {
        if let object = value as? [String: Any] {
            if object.count == 1, let reference = object["$ref"] as? String,
               reference.hasPrefix("#/$defs/"),
               let fragment = shared[String(reference.dropFirst(8))] {
                return inline(fragment, shared: shared)
            }
            return object.mapValues { inline($0, shared: shared) }
        }
        if let array = value as? [Any] { return array.map { inline($0, shared: shared) } }
        return value
    }

    public static func removingComments(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { $0.key != "$comment" }.mapValues(removingComments)
        }
        if let array = value as? [Any] { return array.map(removingComments) }
        return value
    }
}
