import CoreFoundation
import Foundation

/// A JSON-RPC request ID: a string or an integer, echoed back with its type.
public enum JSONRPCID: Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)

    public var json: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        }
    }

    /// For log-free keys such as in-flight request tracking.
    public var key: String {
        switch self {
        case .string(let value): "s:" + value
        case .int(let value): "i:\(value)"
        }
    }

    /// The bytes the id takes in a response, as `JSONRPC.encode` writes it:
    /// a string's quotes and escapes included (`"a\"b"` is 6), an integer's
    /// digits and sign (at most 20).
    public var encodedByteCount: Int {
        switch self {
        case .int(let value): return String(value).utf8.count
        case .string:
            // Inside an array, so the writer takes it on every macOS version.
            guard let data = try? JSONSerialization.data(withJSONObject: [json], options: JSONRPC.writingOptions)
            else { return .max }
            return data.count - 2
        }
    }

    /// Strings and whole numbers only; null, booleans and fractions are invalid.
    public init?(json value: Any) {
        if let text = value as? String {
            self = .string(text)
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            // Integers are read as integers, so large IDs echo exactly;
            // anything outside Int64 is refused.
            // A number written with a fraction or exponent (1.0, 1e3) can't be
            // echoed with its type, so it's refused like any non-integer.
            guard !CFNumberIsFloatType(number), number.stringValue == String(number.int64Value)
            else { return nil }
            self = .int(Int(number.int64Value))
        } else {
            return nil
        }
    }
}

/// One message from a client. MCP removed batching in 2025-06-18, so a body
/// is exactly one object.
public enum JSONRPCMessage {
    case request(id: JSONRPCID, method: String, params: [String: Any])
    case notification(method: String, params: [String: Any])
    /// A client's reply to a server request. We never send requests, so these
    /// are accepted and ignored.
    case response
}

public enum JSONRPCParseError: Error, Equatable {
    case parse
    case invalidRequest
    /// The request was malformed but its ID could be read, so the error can
    /// name it.
    case invalidRequestWithID(JSONRPCID)
    /// The id is longer than the cap once encoded. Answered as an invalid
    /// request with id null, since echoing it is what the cap prevents.
    case idTooLong
}

public enum JSONRPC {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// Implementation-defined: the bearer key wasn't recognized.
    public static let authenticationFailed = -32001
    /// Reserved by MCP 2026-07-28 for Streamable HTTP header problems.
    public static let headerMismatch = -32020
    public static let unsupportedProtocolVersion = -32022

    /// The longest id accepted, in encoded bytes (`JSONRPCID.encodedByteCount`),
    /// so an app can budget a response exactly. Real clients send short
    /// counters or UUIDs.
    public static let defaultMaxIDBytes = 1_024

    /// `maxIDBytes` applies to every message with an id, before any error
    /// that would echo it.
    public static func parse(_ body: Data, maxIDBytes: Int = defaultMaxIDBytes)
        -> Result<JSONRPCMessage, JSONRPCParseError> {
        guard let value = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        else { return .failure(.parse) }
        guard let object = value as? [String: Any] else { return .failure(.invalidRequest) }
        let id = object["id"].flatMap(JSONRPCID.init(json:))
        if let id, id.encodedByteCount > maxIDBytes { return .failure(.idTooLong) }
        guard object["jsonrpc"] as? String == "2.0" else {
            return .failure(id.map(JSONRPCParseError.invalidRequestWithID) ?? .invalidRequest)
        }
        if object["method"] == nil, object["id"] != nil,
           object["result"] != nil || object["error"] != nil {
            return .success(.response)
        }
        guard let method = object["method"] as? String, !method.isEmpty else {
            return .failure(id.map(JSONRPCParseError.invalidRequestWithID) ?? .invalidRequest)
        }
        let params: [String: Any]
        switch object["params"] {
        case nil: params = [:]
        case let value as [String: Any]: params = value
        default: return .failure(id.map(JSONRPCParseError.invalidRequestWithID) ?? .invalidRequest)
        }
        guard object["id"] != nil else { return .success(.notification(method: method, params: params)) }
        guard let id else { return .failure(.invalidRequest) }
        return .success(.request(id: id, method: method, params: params))
    }

    public static func result(id: JSONRPCID, _ result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id.json, "result": result])
    }

    /// `id` nil writes `"id": null`; `omitID` leaves the member out, as MCP
    /// asks for the Origin refusal.
    public static func error(id: JSONRPCID?, code: Int, message: String, data: Any? = nil,
                      omitID: Bool = false) -> Data {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        var object: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if !omitID { object["id"] = id?.json ?? NSNull() }
        return encode(object)
    }

    static let writingOptions: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]

    public static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: writingOptions))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}
