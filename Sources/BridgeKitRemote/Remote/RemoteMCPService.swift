import BridgeKitCore
import Foundation

/// Remote Access settings the listener needs, read on the HTTP queue.
public struct RemoteConfiguration: Equatable, Sendable {
    /// 22 base64url characters; the MCP endpoint is `/r/<secret>/mcp`.
    public var secret: String
    /// `https://my-mac.tail1234.ts.net`, or nil until the user enters it.
    public var publicOrigin: String?
    public var port: Int

    public var secretPrefix: String { "/r/" + secret }

    /// While Switch Tunnel… or Address ▸ Edit… tests a new address (plan 08
    /// T05): accepted for the health check only, never for MCP or OAuth, and
    /// never saved. Nil otherwise.
    public var candidateOrigin: String? = nil

    public init(secret: String, publicOrigin: String?, port: Int, candidateOrigin: String? = nil) {
        self.secret = secret
        self.publicOrigin = publicOrigin
        self.port = port
        self.candidateOrigin = candidateOrigin
    }

    /// Hosts a tunnel may present: the public hostname (Tailscale Funnel keeps
    /// it), or this port on loopback (tunnels that rewrite Host).
    public var allowedHosts: Set<String> {
        Set(["127.0.0.1:\(port)", "localhost:\(port)"]).union(Self.hosts(publicOrigin))
    }

    /// The candidate's Host values, with the same port rules.
    public var candidateHosts: Set<String> { Self.hosts(candidateOrigin) }

    private static func hosts(_ origin: String?) -> Set<String> {
        var hosts = Set<String>()
        if let url = origin.flatMap(URL.init(string:)), let host = url.host?.lowercased() {
            if let port = url.port {
                hosts.insert(host + ":\(port)")
                if port == 443 { hosts.insert(host) }
            } else {
                hosts.insert(host)
                hosts.insert(host + ":443")
            }
        }
        return hosts
    }

    public var oauthContext: OAuthContext? {
        publicOrigin.map { OAuthContext(publicOrigin: $0, secretPrefix: secretPrefix) }
    }

    /// The URL cloud agents use, once the public address is known.
    public var mcpURL: String? { publicOrigin.map { $0 + secretPrefix + "/mcp" } }

    public static func newSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func validSecret(_ secret: String) -> Bool {
        secret.utf8.count == 22 && secret.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// `https://host` with an optional port, nothing else.
    public static func normalizedOrigin(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
        else { return nil }
        return "https://" + host.lowercased() + (url.port.map { ":\($0)" } ?? "")
    }
}

/// The checks for the Remote Access port, in order: path secret (unknown
/// paths are 404 before anything else, so scanners learn nothing), Host,
/// then per-route rules. Runs on the HTTP queue.
public enum RemoteHTTPGate {
    public enum Verdict: Sendable {
        case respond(HTTPResponse, close: Bool)
        case mcp(token: String?, address: String)
        case health(nonce: String, headers: [String], tunnel: TunnelProvider?)
        case oauth(address: String)
    }

    /// Headers tunnels add. Never trusted for authorization: anything on this
    /// Mac can set them. Used for display and the per-address lockout.
    public static let tunnelHeaders = ["tailscale-funnel-request", "cf-ray", "cf-connecting-ip", "x-forwarded-for",
                                "x-forwarded-host", "x-forwarded-proto"]

    /// `originRefused` is the 403 body's message (the app's `RemoteTexts.originRefused`).
    public static func check(_ request: HTTPRequest, configuration: RemoteConfiguration,
                             originRefused: String = "Requests from web pages aren't accepted.") -> Verdict {
        let path = request.path
        let prefix = configuration.secretPrefix
        let route: String
        if path.hasPrefix("/.well-known/") {
            // Discovery documents insert the issuer path after the well-known name.
            guard let range = path.range(of: "/r/"), secretMatches(path[range.lowerBound...], prefix) else {
                return .respond(notFound(), close: false)
            }
            route = "oauth"
        } else if secretMatches(path[...], prefix) {
            let rest = String(path.dropFirst(prefix.count))
            switch rest {
            case "/mcp": route = "mcp"
            case "/health": route = "health"
            default:
                guard rest.hasPrefix("/oauth/") || rest == "/.well-known/openid-configuration" else {
                    return .respond(notFound(), close: false)
                }
                route = "oauth"
            }
        } else {
            return .respond(notFound(), close: false)
        }
        let host = (request.header("host") ?? "").lowercased()
        // A candidate address being tested gets the health check and nothing else.
        guard configuration.allowedHosts.contains(host)
                || (route == "health" && configuration.candidateHosts.contains(host)) else {
            return .respond(HTTPResponse(status: 421), close: true)
        }
        let address = forwardedAddress(request)
        switch route {
        case "health":
            guard request.method == "GET",
                  let nonce = query(request.target)["nonce"], !nonce.isEmpty, nonce.utf8.count <= 64 else {
                return .respond(notFound(), close: false)
            }
            // Detected from the full headers: ngrok and quick tunnels are told apart by host values.
            let tunnel = TunnelProvider.detect(headers: request.headers.map { ($0.name, $0.value) })
            return .health(nonce: nonce, headers: tunnelHeaders.filter { request.header($0) != nil },
                           tunnel: tunnel)
        case "oauth":
            return .oauth(address: address)
        default:
            break
        }
        if request.header("origin") != nil {
            return .respond(MCPHTTPGate.json(403, JSONRPC.error(
                id: nil, code: JSONRPC.invalidRequest,
                message: originRefused, omitID: true)), close: false)
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
            return .mcp(token: nil, address: address)
        }
        return .mcp(token: String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces),
                    address: address)
    }

    /// The caller's address as the tunnel reported it, for the lockout key and
    /// display only. Tailscale Funnel, Cloudflare and ngrok all append the
    /// address they saw to `X-Forwarded-For`, so its last entry is the one the
    /// caller can't choose; `CF-Connecting-IP` passes through Funnel and ngrok
    /// as sent, so it's used only without `X-Forwarded-For`.
    public static func forwardedAddress(_ request: HTTPRequest) -> String {
        if let forwarded = request.header("x-forwarded-for")?.split(separator: ",").last
            .map({ $0.trimmingCharacters(in: .whitespaces) }), validAddress(forwarded) {
            return forwarded
        }
        if let cloudflare = request.header("cf-connecting-ip"), validAddress(cloudflare) { return cloudflare }
        return "unknown"
    }

    private static func validAddress(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 45 &&
            text.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
    }

    /// Compares the secret segment without stopping at the first difference.
    private static func secretMatches(_ path: Substring, _ prefix: String) -> Bool {
        let candidate = Array(path.utf8.prefix(prefix.utf8.count))
        let expected = Array(prefix.utf8)
        guard candidate.count == expected.count else { return false }
        if path.utf8.count > expected.count, path.utf8[path.utf8.index(path.utf8.startIndex,
                                                                        offsetBy: expected.count)] != 47 {
            return false
        }
        var difference: UInt8 = 0
        for index in 0..<expected.count { difference |= candidate[index] ^ expected[index] }
        return difference == 0
    }

    public static func query(_ target: String) -> [String: String] {
        guard let mark = target.firstIndex(of: "?") else { return [:] }
        var result = [String: String]()
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first?.removingPercentEncoding else { continue }
            result[name] = parts.count > 1 ? parts[1].replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding : ""
        }
        return result
    }

    public static func notFound() -> HTTPResponse { MCPHTTPGate.text(404, "Not found.\n") }
}

/// Nonces issued for the Remote Access page ▸ Test. The health endpoint
/// answers only for a nonce issued in the last 30 seconds, which proves the
/// public URL reaches this app. Thread-safe.
public final class RemoteNonces: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = [String: Date]()

    public init() {}

    public func issue() -> String {
        let nonce = RemoteConfiguration.newSecret()
        lock.lock()
        issued = issued.filter { Date().timeIntervalSince($0.value) < 30 }
        issued[nonce] = Date()
        lock.unlock()
        return nonce
    }

    public func consume(_ nonce: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = issued.removeValue(forKey: nonce) else { return false }
        return Date().timeIntervalSince(at) < 30
    }
}

/// The last 50 remote requests' tunnel and forwarded address, in memory
/// only, for Activity's inspector. Never written to disk.
public struct RemoteRequestNote: Equatable, Sendable {
    public let at: Date
    /// The app's id for the agent.
    public let clientID: String
    /// The tunnel its headers point to; display only.
    public let tunnel: TunnelProvider?
    /// The forwarded address (`RemoteHTTPGate.forwardedAddress`); display only.
    public let address: String

    public init(at: Date, clientID: String, tunnel: TunnelProvider?, address: String) {
        self.at = at
        self.clientID = clientID
        self.tunnel = tunnel
        self.address = address
    }
}

/// Runs the Remote Access listener: a second loopback port that only a tunnel
/// should reach, with its own credentials. Every request that passes the gate
/// and authenticates goes to the same `MCPServer` as the local port, with
/// `MCPAuthentication(remote: true)`.
@MainActor
public final class RemoteMCPService {
    public enum Status: Equatable, Sendable {
        case off
        case starting
        case listening(port: Int)
        case failed(LoopbackHTTPServer.Failure)
    }

    public private(set) var status = Status.off {
        didSet { if status != oldValue { statusChanged(status) } }
    }
    public var statusChanged: (Status) -> Void = { _ in }
    /// Called on the main actor for each authenticated remote request.
    public var didServe: (RemoteRequestNote) -> Void = { _ in }

    public let nonces = RemoteNonces()
    public let configuration: RemoteBridgeConfiguration
    private let server: MCPServer
    private let authenticator: RemoteAuthenticator
    private let limiter: RateLimiter
    private let counters: MCPTrafficCounters
    private let oauth: OAuthServer?
    private let http: HTTPLimits
    private let maxConnections: Int
    private let settingsBox = Box()
    private var listener: LoopbackHTTPServer?
    private var generation = 0

    /// `limiter` keeps the per-address lockout of failed authentications;
    /// `http` and `maxConnections` default to the local port's.
    public init(server: MCPServer, configuration: RemoteBridgeConfiguration, authenticator: RemoteAuthenticator,
                limiter: RateLimiter, counters: MCPTrafficCounters, oauth: OAuthServer?,
                http: HTTPLimits? = nil, maxConnections: Int? = nil) {
        self.server = server
        self.configuration = configuration
        self.authenticator = authenticator
        self.limiter = limiter
        self.counters = counters
        self.oauth = oauth
        self.http = http ?? server.configuration.http
        self.maxConnections = maxConnections ?? server.configuration.maxConnections
    }

    /// The settings in use (secret, address, port), or nil before the first start.
    public var settings: RemoteConfiguration? { settingsBox.value }

    /// Applies new settings without restarting when only the address or
    /// secret changed.
    public func update(_ settings: RemoteConfiguration) {
        let restart = settingsBox.value?.port != settings.port
        settingsBox.value = settings
        if restart && listener != nil { start(settings) }
    }

    public func start(_ settings: RemoteConfiguration) {
        stopListener()
        settingsBox.value = settings
        generation += 1
        let current = generation
        let listener = LoopbackHTTPServer(port: settings.port, limits: http, maxConnections: maxConnections,
                                          handler: makeHandler())
        self.listener = listener
        status = .starting
        listener.start { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                switch state {
                case .ready(let port):
                    // The Host check uses the port actually bound (0 picks one in tests).
                    self.settingsBox.value?.port = port
                    self.status = .listening(port: port)
                case .failed(let failure):
                    self.stopListener()
                    self.status = .failed(failure)
                case .stopped, .starting: break
                }
            }
        }
    }

    public func stop() {
        stopListener()
        status = .off
    }

    private func stopListener() {
        generation += 1
        listener?.stop()
        listener = nil
    }

    private func makeHandler() -> LoopbackHTTPServer.Handler {
        let box = settingsBox
        let limiter = limiter
        let counters = counters
        let nonces = nonces
        let texts = configuration.texts
        let remotePrefix = configuration.remoteTokenPrefix
        let accessPrefix = configuration.accessTokenPrefix
        return { [weak self] request, connection, reply in
            let send: @Sendable (HTTPResponse, Bool) -> Void = { response, close in
                counters.record(status: response.status)
                reply(response, close)
            }
            guard let settings = box.value else { return send(RemoteHTTPGate.notFound(), true) }
            switch RemoteHTTPGate.check(request, configuration: settings, originRefused: texts.originRefused) {
            case .respond(let response, let close):
                send(response, close)
            case .health(let nonce, let headers, let tunnel):
                guard nonces.consume(nonce) else { return send(RemoteHTTPGate.notFound(), false) }
                let body: [String: Any] = ["ok": true, "nonce": nonce, "headers": headers,
                                           "tunnel": tunnel?.wireName ?? NSNull()]
                send(MCPHTTPGate.json(200, JSONRPC.encode(body)), false)
            case .oauth:
                // No lockout here: these endpoints take no guessable secret (codes and tokens carry
                // 256 bits), and a lockout keyed on a forwarded address would let anyone block
                // token refreshes for everybody.
                // A Task rather than DispatchQueue.main: hosts that drain the main
                // queue with dispatchMain() run it off the main thread.
                Task { @MainActor in
                    guard let self, let oauth = self.oauth, let context = settings.oauthContext,
                          oauth.handle(request, context: context, reply: { send($0, false) }) else {
                        send(RemoteHTTPGate.notFound(), false)
                        return
                    }
                }
            case .mcp(let token, let address):
                // Under lockout, refuse requests without a plausible credential off the main actor.
                // A well-formed token is always checked, so a locked-out address (which a caller can
                // claim for someone else) never blocks an agent with valid credentials.
                let plausible = token.map {
                    AgentKey.isValid($0, prefix: remotePrefix) || OAuthServer.validToken($0, prefix: accessPrefix)
                } ?? false
                if !plausible, let wait = limiter.remoteAuthLockout(address) {
                    counters.recordAuthFailure()
                    return send(MCPHTTPGate.lockedOut(retryAfter: wait), true)
                }
                let tunnel = TunnelProvider.detect(headers: request.headers.map { ($0.name, $0.value) })
                Task { @MainActor in
                    guard let self else { return }
                    let auth = self.authentication(settings: settings, address: address, tunnel: tunnel)
                    self.server.handle(request, key: token ?? "", auth: auth, whenClosed: { action in
                        let action = MainActorBox(action)
                        return connection.whenClosed {
                            Task { @MainActor in action.value() }
                        }
                    }, reply: { send($0.response, $0.close) })
                }
            }
        }
    }

    /// Remote tokens and OAuth access tokens. Local MCP keys are refused here,
    /// so a key leaked from an agent config on this Mac is useless from the
    /// internet.
    private func authentication(settings: RemoteConfiguration, address: String,
                                tunnel: TunnelProvider?) -> MCPAuthentication {
        MCPAuthentication(authenticate: { [weak self] token in
            guard let self else { return .unavailable }
            let outcome: AuthenticationOutcome
            if AgentKey.isValid(token, prefix: self.configuration.remoteTokenPrefix) {
                outcome = await self.authenticator.authenticate(remoteToken: PresentedKey(token))
            } else if token.hasPrefix(self.configuration.accessTokenPrefix), let oauth = self.oauth,
                      let resource = settings.oauthContext?.resource,
                      let agentID = oauth.authenticate(accessToken: token, resource: resource) {
                outcome = await self.authenticator.authenticate(agentID: agentID)
            } else {
                self.authenticator.recordFailedRemoteAuth()
                outcome = .rejected
            }
            if case .authenticated(let agent) = outcome {
                self.didServe(RemoteRequestNote(at: Date(), clientID: agent.id, tunnel: tunnel, address: address))
            }
            return outcome
        }, rejected: { [weak self] in
            self?.counters.recordAuthFailure()
            self?.limiter.recordFailedRemoteAuth(address)
            if let wait = self?.limiter.remoteAuthLockout(address) {
                return MCPServer.Reply(response: MCPHTTPGate.lockedOut(retryAfter: wait), close: true)
            }
            guard let self else { return MCPServer.Reply(response: HTTPResponse(status: 401)) }
            return MCPServer.Reply(response: Self.unauthorized(settings, configuration: self.configuration))
        }, remote: true)
    }

    /// 401 for the remote endpoint. With a public address, the challenge
    /// names the protected-resource metadata so OAuth clients can start.
    public static func unauthorized(_ settings: RemoteConfiguration,
                                    configuration: RemoteBridgeConfiguration) -> HTTPResponse {
        var response = MCPHTTPGate.json(401, JSONRPC.error(
            id: nil, code: JSONRPC.authenticationFailed, message: configuration.texts.unauthorized))
        let challenge = settings.oauthContext.map { OAuthServer.challenge($0, scope: configuration.scope) }
            ?? "Bearer realm=\"\(configuration.identity.displayName)\""
        response.headers.append(("WWW-Authenticate", challenge))
        return response
    }
}

/// The settings, read from the HTTP queue.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RemoteConfiguration?

    var value: RemoteConfiguration? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Carries a main-actor value across a queue hop that ends on the main actor.
struct MainActorBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
