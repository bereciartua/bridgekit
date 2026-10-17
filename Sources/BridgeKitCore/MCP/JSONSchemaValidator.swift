import CoreFoundation
import Foundation

/// Checks tool arguments against the JSON Schema features tool contracts use:
/// `type`, `const`, `enum`, string length, number bounds, array
/// size and uniqueness, `items`, `properties`, `required` and
/// `additionalProperties: false`. Returns the first problem as
/// "field: what was expected", or nil.
public enum JSONSchemaValidator {
    /// What `minLength` and `maxLength` count. EK Bridge counts UTF-8 bytes;
    /// Funes counts Unicode scalars, like its database's `length()`.
    public enum StringLength: Sendable, Equatable {
        case utf8Bytes
        case unicodeScalars
    }

    public static func validate(_ arguments: [String: Any], against schema: [String: Any],
                                counting unit: StringLength = .utf8Bytes) -> String? {
        check(arguments, against: schema, path: "", unit: unit)
    }

    private static func check(_ value: Any, against schema: [String: Any], path: String,
                              unit: StringLength) -> String? {
        let label = path.isEmpty ? "arguments" : path
        if let types = schemaTypes(schema), !types.contains(where: { matches(value, type: $0) }) {
            return "\(label): expected \(describe(types)), got \(describeValue(value))"
        }
        if let constant = schema["const"], !equal(value, constant) {
            return "\(label): must be \(describeValue(constant))"
        }
        if let options = schema["enum"] as? [Any], !options.contains(where: { equal(value, $0) }) {
            let list = options.map(describeValue).joined(separator: ", ")
            return "\(label): expected one of \(list), got \(describeValue(value))"
        }
        if let text = value as? String {
            let length = unit == .utf8Bytes ? text.utf8.count : text.unicodeScalars.count
            let units = unit == .utf8Bytes ? "bytes" : "characters"
            if let minimum = schema["minLength"] as? Int, length < minimum {
                return minimum == 1 ? "\(label): must not be empty"
                    : "\(label): must be at least \(minimum) \(units)"
            }
            if let maximum = schema["maxLength"] as? Int, length > maximum {
                return unit == .utf8Bytes ? "\(label): must be at most \(maximum) bytes of UTF-8, got \(length)"
                    : "\(label): must be at most \(maximum) characters, got \(length)"
            }
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            if let minimum = schema["minimum"] as? NSNumber, number.doubleValue < minimum.doubleValue {
                return "\(label): must be at least \(minimum)"
            }
            if let maximum = schema["maximum"] as? NSNumber, number.doubleValue > maximum.doubleValue {
                return "\(label): must be at most \(maximum)"
            }
        }
        if let items = value as? [Any] {
            if let minimum = schema["minItems"] as? Int, items.count < minimum {
                return "\(label): needs at least \(minimum) item\(minimum == 1 ? "" : "s")"
            }
            if let maximum = schema["maxItems"] as? Int, items.count > maximum {
                return "\(label): allows at most \(maximum) items"
            }
            if schema["uniqueItems"] as? Bool == true {
                for (index, item) in items.enumerated()
                where items[..<index].contains(where: { equal($0, item) }) {
                    return "\(label): \(describeValue(item)) appears more than once"
                }
            }
            if let itemSchema = schema["items"] as? [String: Any] {
                for (index, item) in items.enumerated() {
                    if let problem = check(item, against: itemSchema, path: "\(label)[\(index)]", unit: unit) {
                        return problem
                    }
                }
            }
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for name in schema["required"] as? [String] ?? [] where object[name] == nil {
                return "\(join(path, name)): is required"
            }
            if schema["additionalProperties"] as? Bool == false {
                let allowed = Set(properties.keys)
                if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
                    let names = properties.keys.sorted().joined(separator: ", ")
                    return "\(join(path, unknown)): isn't a known argument" +
                        (names.isEmpty ? "; this tool takes none" : " (expected: \(names))")
                }
            }
            for name in object.keys.sorted() {
                guard let propertySchema = properties[name] as? [String: Any] else { continue }
                if let problem = check(object[name]!, against: propertySchema, path: join(path, name), unit: unit) {
                    return problem
                }
            }
        }
        return nil
    }

    private static func join(_ path: String, _ name: String) -> String {
        path.isEmpty ? name : "\(path).\(name)"
    }

    private static func schemaTypes(_ schema: [String: Any]) -> [String]? {
        if let one = schema["type"] as? String { return [one] }
        return schema["type"] as? [String]
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        let isBool = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch type {
        case "string": return value is String
        case "boolean": return isBool
        case "integer":
            guard !isBool, let number = value as? NSNumber else { return false }
            let double = number.doubleValue
            return double.isFinite && double.rounded() == double && abs(double) < 9.0e15
        case "number":
            guard !isBool, let number = value as? NSNumber else { return false }
            return number.doubleValue.isFinite
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "null": return value is NSNull
        default: return false
        }
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as AnyObject).isEqual(rhs) && matchesKind(lhs, rhs)
    }

    // NSNumber(true).isEqual(1) is true; keep booleans and numbers apart.
    private static func matchesKind(_ lhs: Any, _ rhs: Any) -> Bool {
        func isBool(_ value: Any) -> Bool {
            (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        }
        return isBool(lhs) == isBool(rhs)
    }

    private static func describe(_ types: [String]) -> String {
        let words = types.map { type -> String in
            switch type {
            case "string": "a string"
            case "boolean": "true or false"
            case "integer": "a whole number"
            case "number": "a number"
            case "object": "an object"
            case "array": "an array"
            default: type
            }
        }
        return words.joined(separator: " or ")
    }

    private static func describeValue(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if let text = value as? String {
            let shown = text.count > 64 ? String(text.prefix(64)) + "…" : text
            return "\"\(shown)\""
        }
        if value is [Any] { return "an array" }
        if value is [String: Any] { return "an object" }
        return "a value of another type"
    }
}
