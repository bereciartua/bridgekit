import Foundation

/// The checks that need nothing but the HTTP request, in a fixed order. They
/// run on the HTTP queue, so a request that fails here never reaches the main
/// actor or the app's agent store.
public enum MCPHTTPGate {
    public enum Verdict: Sendable {
        case proceed(key: String)
        /// A missing or malformed key: counted as a failed authentication.
        case unauthenticated
        case respond(HTTPResponse, close: Bool)
    }

    public static let path = "/mcp"
    /// Headers tunnels add. Local agents never send them, so their presence
    /// means a tunnel was pointed at the local port by mistake.
    public static let defaultForwardedHeaders = ["tailscale-funnel-request", "cf-connecting-ip", "cf-ray",
                                                 "x-forwarded-host"]

    public static func check(_ request: HTTPRequest, port: Int, configuration: BridgeConfiguration) -> Verdict {
        guard request.path == path else {
            return .respond(text(404, "Not found. The MCP endpoint is \(path).\n"), close: false)
        }
        // DNS rebinding defense: a page on evil.example resolving to 127.0.0.1
        // still sends Host: evil.example.
        let host = (request.header("host") ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return .respond(HTTPResponse(status: 421), close: true)
        }
        if let origin = request.header("origin"), !configuration.allowedOrigins.contains(origin) {
            return .respond(json(403, JSONRPC.error(
                id: nil, code: JSONRPC.invalidRequest,
                message: configuration.texts.originRefused, omitID: true)), close: false)
        }
        let forwarded = request.headers.contains { field in
            configuration.forwardedHeaders.contains(field.name)
                || configuration.forwardedHeaderPrefixes.contains { field.name.hasPrefix($0) }
        }
        if forwarded {
            return .respond(json(403, JSONRPC.error(
                id: nil, code: JSONRPC.invalidRequest,
                message: configuration.texts.tunnelRefused, omitID: true)), close: false)
        }
        guard request.method == "POST" else {
            return .respond(HTTPResponse(status: 405, headers: [("Allow", "POST")]), close: false)
        }
        let contentType = (request.header("content-type") ?? "").split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard contentType == "application/json" else {
            return .respond(HTTPResponse(status: 415), close: false)
        }
        if let accept = request.header("accept") {
            let types = accept.split(separator: ",").map {
                $0.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            }
            guard types.contains(where: { ["application/json", "application/*", "*/*"].contains($0) }) else {
                return .respond(HTTPResponse(status: 406), close: false)
            }
        }
        guard let authorization = request.header("authorization"),
              authorization.count > 7, authorization.prefix(7).lowercased() == "bearer " else {
            return .unauthenticated
        }
        let key = String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        guard AgentKey.isValid(key, prefix: configuration.keyPrefix) else { return .unauthenticated }
        return .proceed(key: key)
    }

    public static func unauthorized(_ configuration: BridgeConfiguration) -> HTTPResponse {
        var response = json(401, JSONRPC.error(
            id: nil, code: JSONRPC.authenticationFailed, message: configuration.texts.unauthorized))
        // No resource_metadata parameter, so clients don't start OAuth.
        response.headers.append(("WWW-Authenticate", "Bearer realm=\"\(configuration.identity.displayName)\""))
        return response
    }

    public static func lockedOut(retryAfter: Int) -> HTTPResponse {
        HTTPResponse(status: 429, headers: [("Retry-After", String(retryAfter))])
    }

    public static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: body)
    }

    public static func text(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")],
                     body: Data(body.utf8))
    }
}

/// Counts only, never bodies: an app can show them to help debug agent
/// setups without logging data.
public final class MCPTrafficCounters: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var requests = 0
        public var byStatus = [Int: Int]()
        public var authFailures = 0
    }

    private let lock = NSLock()
    private var current = Snapshot()

    public init() {}

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func record(status: Int) {
        lock.lock()
        current.requests += 1
        if status >= 400 { current.byStatus[status, default: 0] += 1 }
        lock.unlock()
    }

    public func recordAuthFailure() {
        lock.lock()
        current.authFailures += 1
        lock.unlock()
    }
}

/// How one listener authenticates its callers. The local port uses the app's
/// `AgentAuthenticator`; an app's remote transport passes its own. Everything
/// after authentication is shared.
public struct MCPAuthentication {
    public let authenticate: @MainActor (String) async -> AuthenticationOutcome
    /// The answer to a missing or wrong credential (may be a lockout).
    public let rejected: @MainActor () -> MCPServer.Reply
    public let remote: Bool

    public init(authenticate: @escaping @MainActor (String) async -> AuthenticationOutcome,
                rejected: @escaping @MainActor () -> MCPServer.Reply, remote: Bool) {
        self.authenticate = authenticate
        self.rejected = rejected
        self.remote = remote
    }
}

/// The MCP protocol on top of the HTTP gate: authentication, both protocol
/// eras, and method dispatch. Stateless: no sessions are minted, so every
/// request stands alone and a restart loses nothing.
@MainActor
public final class MCPServer {
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    public static let legacyDefault = "2025-11-25"
    public static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    public static let metaCapabilities = "io.modelcontextprotocol/clientCapabilities"
    public static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    public static let metaServerInfo = "io.modelcontextprotocol/serverInfo"

    public struct Reply: Sendable {
        public let response: HTTPResponse
        public var close = false

        public init(response: HTTPResponse, close: Bool = false) {
            self.response = response
            self.close = close
        }
    }

    /// The last authenticated MCP request from an agent, for "Connected ·
    /// Claude Code 2.4.1 · 2 min ago". In memory only.
    public struct Connection: Equatable, Sendable {
        public let at: Date
        public let agent: String?
        /// Through a remote transport rather than from this Mac.
        public var remote = false

        public init(at: Date, agent: String?, remote: Bool = false) {
            self.at = at
            self.agent = agent
            self.remote = remote
        }
    }

    /// One tool call between dispatch and its answer.
    private final class PendingCall {
        var answered = false
        var unregister: (() -> Void)?
    }

    public let configuration: BridgeConfiguration
    private let authenticator: AgentAuthenticator
    private let tools: ToolRegistry
    private let handler: BridgeHandler
    private let limiter: RateLimiter
    private let counters: MCPTrafficCounters
    private let now: () -> Date
    private let didConnect: (String, Connection) -> Void
    private var agents = [String: String]()
    /// Keyed by agent and JSON-RPC id. Two sessions of one agent can reuse
    /// an id, so each key holds a list.
    private var inFlight = [String: [CallContext]]()

    public init(configuration: BridgeConfiguration, authenticator: AgentAuthenticator, tools: ToolRegistry,
                handler: BridgeHandler, limiter: RateLimiter, counters: MCPTrafficCounters,
                now: @escaping () -> Date = Date.init,
                didConnect: @escaping (String, Connection) -> Void = { _, _ in }) {
        self.configuration = configuration
        self.authenticator = authenticator
        self.tools = tools
        self.handler = handler
        self.limiter = limiter
        self.counters = counters
        self.now = now
        self.didConnect = didConnect
    }

    /// Called on the main actor for a request that passed `MCPHTTPGate`.
    /// `whenClosed` registers work to run if the connection goes away first;
    /// it returns a closure that unregisters it.
    public func handle(_ request: HTTPRequest, key: String, auth: MCPAuthentication? = nil,
                       whenClosed: @escaping (@escaping @MainActor () -> Void) -> () -> Void,
                       reply: @escaping (Reply) -> Void) {
        let auth = auth ?? localAuthentication
        Task { @MainActor in
            let outcome = await auth.authenticate(key)
            self.dispatch(request, outcome: outcome, auth: auth, whenClosed: whenClosed, reply: reply)
        }
    }

    private func dispatch(_ request: HTTPRequest, outcome: AuthenticationOutcome, auth: MCPAuthentication,
                          whenClosed: @escaping (@escaping @MainActor () -> Void) -> () -> Void,
                          reply: @escaping (Reply) -> Void) {
        let agent: AuthenticatedAgent
        switch outcome {
        case .authenticated(let found): agent = found
        case .unavailable:
            reply(Reply(response: MCPHTTPGate.json(503, JSONRPC.error(
                id: nil, code: JSONRPC.internalError, message: configuration.texts.unavailable))))
            return
        case .rejected:
            reply(auth.rejected())
            return
        }
        let remote = auth.remote
        let message: JSONRPCMessage
        switch JSONRPC.parse(request.body) {
        case .success(let parsed): message = parsed
        case .failure(.parse):
            reply(error(400, nil, JSONRPC.parseError, "Parse error: the body isn't valid JSON."))
            return
        case .failure(.invalidRequestWithID(let id)):
            reply(error(400, id, JSONRPC.invalidRequest, "Invalid request."))
            return
        case .failure(.invalidRequest):
            reply(error(400, nil, JSONRPC.invalidRequest,
                        "Invalid request: send one JSON-RPC 2.0 object (batches aren't supported)."))
            return
        }
        let id: JSONRPCID?
        let method: String
        let params: [String: Any]
        switch message {
        case .response:
            reply(Reply(response: HTTPResponse(status: 202)))
            return
        case .notification(let name, let values): (id, method, params) = (nil, name, values)
        case .request(let requestID, let name, let values): (id, method, params) = (requestID, name, values)
        }

        // Era detection, per request.
        let header = request.header("mcp-protocol-version")
        let meta = params["_meta"] as? [String: Any]
        let modern: Bool
        if let version = meta?[Self.metaVersion] {
            guard let version = version as? String, header == version else {
                reply(error(400, id, JSONRPC.headerMismatch,
                            "MCP-Protocol-Version must match _meta \(Self.metaVersion)."))
                return
            }
            guard Self.modernVersions.contains(version) else {
                reply(error(400, id, JSONRPC.unsupportedProtocolVersion,
                            "Unsupported protocol version \(version).",
                            data: ["supported": Self.modernVersions + Self.legacyVersions,
                                   "requested": version]))
                return
            }
            guard meta?[Self.metaCapabilities] is [String: Any] else {
                reply(error(400, id, JSONRPC.invalidParams,
                            "Missing _meta \(Self.metaCapabilities)."))
                return
            }
            guard request.header("mcp-method") == method else {
                reply(error(400, id, JSONRPC.headerMismatch, "Mcp-Method must match the method."))
                return
            }
            if method == "tools/call" {
                guard let name = request.header("mcp-name").flatMap(Self.decodeHeaderValue),
                      name == params["name"] as? String else {
                    reply(error(400, id, JSONRPC.headerMismatch, "Mcp-Name must match params.name."))
                    return
                }
            }
            modern = true
        } else if method == "initialize" {
            modern = false
        } else {
            if let header {
                if Self.modernVersions.contains(header) {
                    reply(error(400, id, JSONRPC.invalidParams,
                                "Protocol version \(header) requires _meta \(Self.metaVersion) "
                                    + "and \(Self.metaCapabilities) on every request."))
                    return
                }
                guard Self.legacyVersions.contains(header) else {
                    reply(error(400, id, JSONRPC.unsupportedProtocolVersion,
                                "Unsupported protocol version \(header).",
                                data: ["supported": Self.modernVersions + Self.legacyVersions,
                                       "requested": header]))
                    return
                }
            }
            modern = false
        }

        // Local and remote sessions of one agent are remembered apart.
        let agentKey = (remote ? "remote|" : "") + agent.id
        if let info = (meta?[Self.metaClientInfo] ?? (method == "initialize" ? params["clientInfo"] : nil))
            as? [String: Any], let name = Self.agentName(info) {
            agents[agentKey] = name
        }
        let agentName = agents[agentKey]
        didConnect(agent.id, Connection(at: now(), agent: agentName, remote: remote))

        guard let id else {
            // Notifications: accepted and, apart from cancellation, ignored.
            if method == "notifications/cancelled",
               let target = params["requestId"].flatMap(JSONRPCID.init(json:)) {
                inFlight[agent.id + "|" + target.key]?.forEach { $0.cancel() }
            }
            reply(Reply(response: HTTPResponse(status: 202)))
            return
        }

        let finish: ([String: Any]) -> Void = { result in
            reply(self.result(id, result, modern: modern))
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            finish([
                "protocolVersion": Self.legacyVersions.contains(requested) ? requested : Self.legacyDefault,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": serverInfo(full: true),
                "instructions": tools.serverInstructions,
            ])
        case "server/discover":
            var result: [String: Any] = [
                "supportedVersions": Self.modernVersions + Self.legacyVersions,
                "capabilities": ["tools": [String: Any]()],
                "instructions": tools.serverInstructions,
            ]
            if let name = agent.name {
                // Lets `<launcher> check` name the agent the key belongs to.
                result["_meta"] = [configuration.agentMetaKey: ["name": name]]
            }
            finish(result)
        case "ping" where !modern:
            finish([:])
        case "tools/list":
            var result: [String: Any] = [
                "tools": tools.visibleTools(for: agent).map(\.definition),
            ]
            if modern {
                // The list varies by key, so it must not be shared between agents.
                result["ttlMs"] = 30_000
                result["cacheScope"] = "private"
            }
            finish(result)
        case "tools/call":
            callTool(id: id, params: params, agent: agent, agentName: agentName, remote: remote,
                     whenClosed: whenClosed, finish: finish,
                     unknownTool: { reply(self.error(200, id, JSONRPC.invalidParams, $0)) })
        default:
            reply(error(modern ? 404 : 200, id, JSONRPC.methodNotFound, "Method not found: \(method)"))
        }
    }

    private func callTool(id: JSONRPCID, params: [String: Any], agent: AuthenticatedAgent, agentName: String?,
                          remote: Bool, whenClosed: (@escaping @MainActor () -> Void) -> () -> Void,
                          finish: @escaping ([String: Any]) -> Void,
                          unknownTool: (String) -> Void) {
        // An unknown name is a protocol error; everything after is a tool error
        // the model can act on.
        guard let name = params["name"] as? String, let tool = tools.tool(named: name) else {
            unknownTool("Unknown tool: \(params["name"] as? String ?? "")")
            return
        }
        let arguments: [String: Any]
        switch params["arguments"] {
        case nil, is NSNull: arguments = [:]
        case let object as [String: Any]: arguments = object
        default:
            finish(tools.failureResult(.invalidArguments("arguments: expected an object"),
                                       tool: name, arguments: nil).json)
            return
        }
        // The model's typos never reach the handler, so they aren't Activity rows.
        if let problem = JSONSchemaValidator.validate(arguments, against: tool.inputSchema) {
            finish(tools.failureResult(.invalidArguments(problem), tool: name, arguments: arguments).json)
            return
        }
        let context = CallContext()
        let call = ToolCall(name: name, arguments: arguments, agent: agent, agentName: agentName,
                            remote: remote, context: context)
        let pending = PendingCall()
        let key = agent.id + "|" + id.key
        let answer: ([String: Any]) -> Void = { [weak self] result in
            guard !pending.answered else { return }
            pending.answered = true
            pending.unregister?()
            pending.unregister = nil
            if let self {
                self.inFlight[key]?.removeAll { $0 === context }
                if self.inFlight[key]?.isEmpty == true { self.inFlight[key] = nil }
            }
            finish(result)
        }
        inFlight[key, default: []].append(context)
        // A disconnect cancels; what that means for a call in progress is the app's choice.
        pending.unregister = whenClosed { [weak context] in context?.cancel() }
        let handler = self.handler
        let task = Task { @MainActor in
            let result = await handler.handle(call)
            answer(result.json)
        }
        context.onCancel { task.cancel() }
        // Answer before the agent's own timeout, so it gets the app's words.
        // The call isn't cancelled: a change in progress may still finish.
        let nanoseconds = UInt64(configuration.toolCallTimeout * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !pending.answered, let self else { return }
            answer((context.timeoutResult ?? self.tools.failureResult(.timeout, tool: name, arguments: arguments)).json)
        }
    }

    private var localAuthentication: MCPAuthentication {
        let authenticator = self.authenticator
        let configuration = self.configuration
        return MCPAuthentication(
            authenticate: { await authenticator.authenticate(PresentedKey($0)) },
            rejected: { [weak self] in
                self?.rejectKey() ?? Reply(response: MCPHTTPGate.unauthorized(configuration))
            },
            remote: false)
    }

    private func rejectKey() -> Reply {
        counters.recordAuthFailure()
        limiter.recordFailedAuth()
        if let wait = limiter.authLockout() {
            return Reply(response: MCPHTTPGate.lockedOut(retryAfter: wait), close: true)
        }
        return Reply(response: MCPHTTPGate.unauthorized(configuration))
    }

    private func result(_ id: JSONRPCID, _ result: [String: Any], modern: Bool) -> Reply {
        var result = result
        if modern {
            // Strict legacy validators may reject unknown fields, so these are modern-only.
            result["resultType"] = "complete"
            var meta = result["_meta"] as? [String: Any] ?? [:]
            meta[Self.metaServerInfo] = serverInfo(full: false)
            result["_meta"] = meta
        }
        return Reply(response: MCPHTTPGate.json(200, JSONRPC.result(id: id, result)))
    }

    private func error(_ status: Int, _ id: JSONRPCID?, _ code: Int, _ message: String,
                       data: Any? = nil) -> Reply {
        Reply(response: MCPHTTPGate.json(status, JSONRPC.error(id: id, code: code, message: message,
                                                               data: data)))
    }

    private func serverInfo(full: Bool) -> [String: Any] {
        var info: [String: Any] = ["name": configuration.serverKey, "version": configuration.identity.version]
        if full {
            info["title"] = configuration.identity.displayName
            info["description"] = configuration.serverDescription
        }
        return info
    }

    /// "name version" as the agent reported it, sanitized; display only.
    public static func agentName(_ info: [String: Any]) -> String? {
        guard let name = info["name"] as? String else { return nil }
        let version = info["version"] as? String
        return AgentName.sanitized([name, version].compactMap { $0 }.joined(separator: " "))
    }

    /// `Mcp-Name` may use `=?base64?…?=` for names that aren't header-safe.
    public static func decodeHeaderValue(_ value: String) -> String? {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?=") else { return value }
        let encoded = value.dropFirst(9).dropLast(2)
        return Data(base64Encoded: String(encoded)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
