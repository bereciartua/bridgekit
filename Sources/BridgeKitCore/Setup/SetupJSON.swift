import Foundation

/// A JSON value written with its members in a fixed order, for agent config
/// snippets and one-click setup.
public indirect enum SetupJSON: Equatable, Sendable {
    case string(String), number(Int), bool(Bool), array([SetupJSON]), object([(String, SetupJSON)])

    public static func strings(_ values: [String]) -> SetupJSON { .array(values.map { .string($0) }) }

    public var text: String {
        switch self {
        case .string(let value):
            let data = try! JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { SetupJSON.string($0.0).text + ":" + $0.1.text }
                .joined(separator: ",") + "}"
        }
    }

    /// Pretty text: `unit` per level, starting at `level` (the first line isn't indented).
    public func pretty(unit: String, level: Int) -> String {
        let inner = String(repeating: unit, count: level + 1)
        let outer = String(repeating: unit, count: level)
        switch self {
        case .array(let items) where !items.isEmpty:
            // Short arrays of plain values stay on one line, as editors write them.
            if items.allSatisfy({ if case .array = $0 { false } else if case .object = $0 { false } else { true } }) {
                return "[" + items.map(\.text).joined(separator: ", ") + "]"
            }
            return "[\n" + items.map { inner + $0.pretty(unit: unit, level: level + 1) }
                .joined(separator: ",\n") + "\n" + outer + "]"
        case .object(let pairs) where !pairs.isEmpty:
            return "{\n" + pairs.map { inner + SetupJSON.string($0.0).text + ": " + $0.1.pretty(unit: unit, level: level + 1) }
                .joined(separator: ",\n") + "\n" + outer + "}"
        default:
            return text
        }
    }

    public static func == (lhs: SetupJSON, rhs: SetupJSON) -> Bool { lhs.text == rhs.text }
}

/// Codex's `[mcp_servers.<key>]` tables.
public enum SetupTOML {
    /// TOML basic strings accept JSON's string escapes, so values reuse SetupJSON's encoding.
    public static func table(_ serverKey: String, _ pairs: [(String, SetupJSON)]) -> String {
        let bare = serverKey.unicodeScalars.allSatisfy { bareKey.contains($0) }
        let name = bare ? serverKey : SetupJSON.string(serverKey).text
        let values = pairs.map { key, value -> String in
            guard case .array(let items) = value else { return "\(key) = \(value.text)" }
            return "\(key) = [" + items.map(\.text).joined(separator: ", ") + "]"
        }
        return (["[mcp_servers.\(name)]"] + values).joined(separator: "\n")
    }

    /// Characters a TOML bare key may use.
    public static let bareKey = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
}
