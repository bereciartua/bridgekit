import CryptoKit
import Foundation

// The seam between BridgeKitCore and an app. The core never sees a calendar or
// a memory: it parses HTTP and JSON-RPC, authenticates keys, validates
// arguments against the app's contract and hands each tool call to the app.

/// Who the app is, for messages, paths and `serverInfo`.
public struct BridgeIdentity: Sendable, Equatable {
    /// "EK Bridge", "Funes Vault". Used in messages agents relay to the user.
    public var displayName: String
    public var bundleID: String
    /// `~/Library/Application Support/<folder>`: the endpoint file and key folder live here.
    public var dataFolder: URL
    /// `serverInfo.version`.
    public var version: String

    public init(displayName: String, bundleID: String, dataFolder: URL, version: String) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.dataFolder = dataFolder
        self.version = version
    }
}

/// The words the server says on the app's behalf. Each app supplies its own
/// so agents see its terms ("client", "agent", "connection").
public struct BridgeTexts: Sendable, Equatable {
    /// 503: the app can't read its agent store.
    public var unavailable: String
    /// 401: a missing or unknown key.
    public var unauthorized: String
    /// 403: a tunnel or forwarding header on the local port.
    public var tunnelRefused: String
    /// 403: an `Origin` header that isn't allowlisted.
    public var originRefused: String

    public init(unavailable: String, unauthorized: String, tunnelRefused: String,
                originRefused: String = "Requests from web pages aren't accepted.") {
        self.unavailable = unavailable
        self.unauthorized = unauthorized
        self.tunnelRefused = tunnelRefused
        self.originRefused = originRefused
    }

    /// Plain defaults built from the display name.
    public static func standard(displayName app: String) -> BridgeTexts {
        BridgeTexts(
            unavailable: "\(app) can't read its agent settings. Ask the user to open \(app).",
            unauthorized: "\(app) doesn't recognize this agent's key. Copy the setup again from the agent's page in \(app).",
            tunnelRefused: "This port is only for agents on this Mac.")
    }
}

/// Everything that differs between apps built on BridgeKitCore.
public struct BridgeConfiguration: Sendable {
    public var identity: BridgeIdentity
    /// 47615 EK Bridge · 47625 Funes. Agents' configs embed it, so it never moves on its own.
    public var mcpPort: Int
    /// "ekb_mcp_v1_" · "fns_mcp_v1_". Keys are the prefix plus 64 lowercase hex digits.
    public var keyPrefix: String
    /// The key agents store this server under ("ek-bridge" · "funes"); `serverInfo.name`.
    public var serverKey: String
    /// The stdio launcher inside the app bundle ("bridge-mcp" · "funes-mcp").
    public var launcherName: String
    /// `serverInfo.description` on `initialize`.
    public var serverDescription: String
    /// The `_meta` key `server/discover` uses to name the agent a key belongs to,
    /// so `<launcher> check` can show it.
    public var agentMetaKey: String
    public var limits: RateLimiter.Policy
    public var http: HTTPLimits
    public var maxConnections: Int
    /// Answer before the agent's own timeout (often 60 s), so it gets the app's words.
    public var toolCallTimeout: TimeInterval
    /// `Origin` values accepted; empty by default (agents don't send one).
    public var allowedOrigins: Set<String>
    /// Headers tunnels add, matched exactly (lowercase). Their presence on the
    /// local port means a tunnel was pointed at it by mistake.
    public var forwardedHeaders: [String]
    /// Header-name prefixes refused the same way ("x-forwarded-", "cf-").
    public var forwardedHeaderPrefixes: [String]
    /// What the contract's `minLength`/`maxLength` count.
    public var stringLength: JSONSchemaValidator.StringLength
    /// The longest JSON-RPC id accepted, in encoded bytes. Longer ones get an
    /// invalid-request error with id null, so a response never carries more
    /// than this for its id.
    public var maxIDBytes: Int
    public var texts: BridgeTexts

    public init(identity: BridgeIdentity, mcpPort: Int, keyPrefix: String, serverKey: String,
                launcherName: String, serverDescription: String, agentMetaKey: String,
                limits: RateLimiter.Policy = RateLimiter.Policy(), http: HTTPLimits = .standard,
                maxConnections: Int = LoopbackHTTPServer.defaultMaxConnections,
                toolCallTimeout: TimeInterval = 55, allowedOrigins: Set<String> = [],
                forwardedHeaders: [String] = MCPHTTPGate.defaultForwardedHeaders,
                forwardedHeaderPrefixes: [String] = [], stringLength: JSONSchemaValidator.StringLength = .utf8Bytes,
                maxIDBytes: Int = JSONRPC.defaultMaxIDBytes, texts: BridgeTexts? = nil) {
        self.identity = identity
        self.mcpPort = mcpPort
        self.keyPrefix = keyPrefix
        self.serverKey = serverKey
        self.launcherName = launcherName
        self.serverDescription = serverDescription
        self.agentMetaKey = agentMetaKey
        self.limits = limits
        self.http = http
        self.maxConnections = maxConnections
        self.toolCallTimeout = toolCallTimeout
        self.allowedOrigins = allowedOrigins
        self.forwardedHeaders = forwardedHeaders
        self.forwardedHeaderPrefixes = forwardedHeaderPrefixes
        self.stringLength = stringLength
        self.maxIDBytes = maxIDBytes
        self.texts = texts ?? .standard(displayName: identity.displayName)
    }
}

/// One thing an agent can ask an app to do. Apps adopt it for their own
/// operation types; policy (approvals, grants) stays in the app.
public protocol BridgeOperation: Sendable {
    var name: String { get }
    var isWrite: Bool { get }
    var needsApproval: Bool { get }
}

extension BridgeOperation {
    public var needsApproval: Bool { false }
}

/// An agent whose key the app recognized.
public struct AuthenticatedAgent: Sendable, Equatable, Hashable {
    /// The app's id for it (EK Bridge's client UUID, Funes's agent UUID).
    public let id: String
    /// The name the user gave it, for `server/discover` (`<launcher> check`).
    public let name: String?

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }
}

/// A key as presented in `Authorization: Bearer`, already checked for shape.
public struct PresentedKey: Sendable {
    public let value: String
    /// SHA-256 of the key's UTF-8 bytes.
    public let digest: Data

    public init(_ value: String) {
        self.value = value
        digest = AgentKey.digest(value)
    }
}

public enum AuthenticationOutcome: Sendable, Equatable {
    case authenticated(AuthenticatedAgent)
    /// Unknown, removed or wrong: 401 (and counted toward the lockout).
    case rejected
    /// The app can't read its agent store: 503, not counted.
    case unavailable
}

/// App-owned storage, core-owned crypto: the app looks the key up in its own
/// store (JSON for EK Bridge, SQLite for Funes) and compares in constant time
/// (`AgentKey.matches`).
public protocol AgentAuthenticator: Sendable {
    func authenticate(_ key: PresentedKey) async -> AuthenticationOutcome
}

/// One tool from the app's contract: its `tools/list` entry and input schema.
public struct ToolDefinition: @unchecked Sendable, BridgeOperation {
    public let name: String
    /// The `tools/list` entry, with shared `$defs` fragments inlined.
    public let definition: [String: Any]
    public var inputSchema: [String: Any] { definition["inputSchema"] as? [String: Any] ?? [:] }
    /// From `annotations.readOnlyHint`: anything not marked read-only is a write.
    public var isWrite: Bool {
        (definition["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool != true
    }

    public init(name: String, definition: [String: Any]) {
        self.name = name
        self.definition = definition
    }
}

/// A validated `tools/call`.
public struct ToolCall: @unchecked Sendable {
    /// The request's id, echoed in the response: `id.encodedByteCount` bytes,
    /// at most `BridgeConfiguration.maxIDBytes`.
    public let id: JSONRPCID
    public let name: String
    /// Checked against the tool's input schema before the handler sees them.
    public let arguments: [String: Any]
    public let agent: AuthenticatedAgent
    /// What the agent says it is (MCP `clientInfo`), sanitized; display only.
    public let agentName: String?
    /// Through a remote transport the app runs, rather than from this Mac.
    public let remote: Bool
    /// Cancellation, and what a timeout means for this call.
    public let context: CallContext

    /// `id` defaults to 0 for calls built by hand, in tests.
    public init(id: JSONRPCID = .int(0), name: String, arguments: [String: Any], agent: AuthenticatedAgent,
                agentName: String?, remote: Bool, context: CallContext) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.agent = agent
        self.agentName = agentName
        self.remote = remote
        self.context = context
    }
}

/// Shared between the transport and the app while a call runs, on the main actor.
@MainActor
public final class CallContext: Sendable {
    /// True once the HTTP connection closed or the agent sent
    /// `notifications/cancelled`; not when the server answered with a timeout.
    public private(set) var isCancelled = false
    /// What the server answers if the handler hasn't by `toolCallTimeout`.
    /// The app sets it once it knows (an idempotency key it generated, say);
    /// otherwise the registry's `failureResult(.timeout, …)` is used.
    public var timeoutResult: ToolResult?
    private var actions = [() -> Void]()

    public nonisolated init() {}

    /// Runs `action` when the call is cancelled (at once if it already was).
    public func onCancel(_ action: @escaping () -> Void) {
        if isCancelled { action() } else { actions.append(action) }
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let pending = actions
        actions.removeAll()
        pending.forEach { $0() }
    }
}

/// A `tools/call` result object (`content`, `structuredContent`, `isError`).
public struct ToolResult: @unchecked Sendable {
    public var json: [String: Any]

    public init(_ json: [String: Any]) { self.json = json }
}

/// Outcomes the core decides before or instead of the handler.
public enum ToolFailure: Sendable, Equatable {
    /// `arguments` isn't an object, or fails the input schema ("field: what was expected").
    case invalidArguments(String)
    /// The handler didn't answer within `toolCallTimeout`.
    case timeout
}

/// The app's tool contract: which tools exist, which an agent sees, and how
/// the core's own failures read in the app's result shape.
@MainActor
public protocol ToolRegistry: AnyObject {
    var serverInstructions: String { get }
    func tool(named name: String) -> ToolDefinition?
    /// Computed per request; `tools/list` is never cached across agents.
    func visibleTools(for agent: AuthenticatedAgent) -> [ToolDefinition]
    func failureResult(_ failure: ToolFailure, tool: String, arguments: [String: Any]?) -> ToolResult
}

/// Runs a validated tool call. Each app's request pipeline (pause, grants,
/// approvals, limits, activity) sits behind this.
public protocol BridgeHandler: Sendable {
    func handle(_ call: ToolCall) async -> ToolResult
}

/// Bearer keys: issue, digest and verify. A key is 32 bytes from the system
/// CSPRNG as 64 lowercase hex digits after an app prefix. Only its SHA-256 is
/// stored; plain SHA-256 is deliberate, because a 256-bit random key has
/// nothing to brute-force and a slow hash would add only latency.
public enum AgentKey {
    public static func issue(prefix: String) -> String {
        // SystemRandomNumberGenerator reads the kernel CSPRNG.
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return prefix + Hex.encode(Data(bytes))
    }

    /// The prefix plus exactly 64 lowercase hex digits.
    public static func isValid(_ key: String, prefix: String) -> Bool {
        key.utf8.count == prefix.utf8.count + 64 && key.hasPrefix(prefix) &&
            key.utf8.dropFirst(prefix.utf8.count).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func digest(_ key: String) -> Data {
        Data(SHA256.hash(data: Data(key.utf8)))
    }

    /// Constant-time comparison of two 32-byte digests.
    public static func matches(_ stored: Data, _ presented: Data) -> Bool {
        guard stored.count == 32, presented.count == 32 else { return false }
        var difference: UInt8 = 0
        for index in 0..<32 { difference |= stored[stored.startIndex + index] ^ presented[presented.startIndex + index] }
        return difference == 0
    }

    /// Finds the entry whose digest matches without stopping early, so the
    /// time taken doesn't depend on which entry (if any) matched.
    public static func firstMatch<ID>(_ presented: Data, in candidates: [(id: ID, digest: Data)]) -> ID? {
        var match: ID?
        for candidate in candidates where matches(candidate.digest, presented) && match == nil {
            match = candidate.id
        }
        return match
    }
}

/// The agent's self-reported name (MCP `clientInfo`) for display: control
/// characters removed, whitespace collapsed, at most `maxBytes` UTF-8 bytes
/// (cut at a character boundary).
public enum AgentName {
    public static let maxBytes = 64

    public static func sanitized(_ raw: String) -> String? {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var result = ""
        for character in cleaned {
            if result.utf8.count + String(character).utf8.count > maxBytes { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }
}
