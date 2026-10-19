import BridgeKitCore
import Foundation
import Testing
@testable import BridgeKitRemote

/// The Remote Access port's gate while a new address is tested (plan 08 T05), and the tunnel the
/// health route reports.
@Suite("Remote gate")
struct RemoteGateTests {
    static let secret = "q7Zk2vN4bXwP9sL1mT6hYa"
    static let prefix = "/r/" + secret
    static let health = prefix + "/health?nonce=abc"
    static let candidate = "quiet-river-1234.trycloudflare.com"
    static let routes: [(String, String)] = [
        ("POST", prefix + "/mcp"), ("GET", prefix + "/oauth/authorize?x=1"), ("POST", prefix + "/oauth/token"),
        ("GET", "/.well-known/oauth-protected-resource" + prefix + "/mcp"),
        ("GET", "/.well-known/oauth-authorization-server" + prefix), ("GET", prefix + "/.well-known/openid-configuration"),
    ]

    static func parse(_ text: String) -> HTTPRequest? {
        var parser = HTTPParser()
        guard case .request(let request) = parser.feed(Data(text.utf8)) else { return nil }
        return request
    }

    /// A good MCP request; a value replaces a header, or adds it.
    static func request(method: String, target: String, _ overrides: KeyValuePairs<String, String> = [:])
        -> HTTPRequest? {
        var headers: [(String, String)] = [
            ("Host", "127.0.0.1:47616"),
            ("Content-Type", "application/json"),
            ("Accept", "application/json, text/event-stream"),
            ("Authorization", "Bearer ekb_mcpr_v1_" + String(repeating: "0123456789abcdef", count: 4)),
        ]
        for (name, value) in overrides {
            if let index = headers.firstIndex(where: { $0.0.lowercased() == name.lowercased() }) {
                headers[index].1 = value
            } else {
                headers.append((name, value))
            }
        }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        return parse(text)
    }

    static func verdict(_ method: String, _ target: String, host: String,
                        configuration: RemoteConfiguration) -> String {
        guard let request = request(method: method, target: target, ["Host": host]) else { return "unparsed" }
        switch RemoteHTTPGate.check(request, configuration: configuration) {
        case .respond(let response, _): return String(response.status)
        case .mcp: return "mcp"
        case .health: return "health"
        case .oauth: return "oauth"
        }
    }

    static let base = RemoteConfiguration(secret: secret, publicOrigin: "https://my-mac.tail1234.ts.net", port: 47616)

    /// Every route the gate lets through is under `publicPaths`, the paths a tunnel shared by path
    /// forwards; discovery documents it doesn't serve, and paths outside them, are 404.
    @Test("every route is under publicPaths, and nothing else is answered")
    func publicPaths() {
        let paths = Self.base.publicPaths
        #expect(paths == [Self.prefix, "/.well-known/oauth-protected-resource" + Self.prefix,
                          "/.well-known/oauth-authorization-server" + Self.prefix,
                          "/.well-known/openid-configuration" + Self.prefix], "the four paths")
        let host = "my-mac.tail1234.ts.net"
        let served = Self.routes + [("GET", Self.prefix + "/health?nonce=abc"), ("POST", Self.prefix + "/oauth/register"),
                                    ("POST", Self.prefix + "/oauth/revoke"), ("GET", Self.prefix + "/oauth/authorize/status"),
                                    ("GET", "/.well-known/openid-configuration" + Self.prefix)]
        for (method, target) in served {
            let path = String(target.prefix { $0 != "?" })
            #expect(RemotePaths.covers(paths, path), "\(path) is under publicPaths")
            #expect(Self.verdict(method, target, host: host, configuration: Self.base) != "404", "\(path) is answered")
        }
        for target in ["/.well-known/security.txt" + Self.prefix, "/.well-known/oauth-protected-resource",
                       "/.well-known/other" + Self.prefix + "/mcp", Self.prefix + "x/mcp", "/r/other/mcp", "/"] {
            #expect(!RemotePaths.covers(paths, target), "\(target) is outside publicPaths")
            #expect(Self.verdict("GET", target, host: host, configuration: Self.base) == "404", "\(target) is 404")
        }
        #expect(RemotePaths.covers([Self.prefix], Self.prefix) && RemotePaths.covers([Self.prefix], Self.prefix + "/mcp")
                && !RemotePaths.covers([Self.prefix], Self.prefix + "x"), "by whole segment")
    }

    /// While a new address is tested, its Host gets the health check only: MCP, OAuth and
    /// discovery with that Host are still 421.
    @Test("no candidate: its Host is 421 everywhere")
    func noCandidate() {
        let configuration = Self.base
        func verdict(_ method: String, _ target: String, host: String) -> String {
            Self.verdict(method, target, host: host, configuration: configuration)
        }
        #expect(verdict("GET", Self.health, host: Self.candidate) == "421", "no candidate, health")
        for (method, target) in Self.routes {
            #expect(verdict(method, target, host: Self.candidate) == "421", "no candidate \(target)")
        }
        #expect(verdict("GET", Self.health, host: "my-mac.tail1234.ts.net") == "health", "the address in use")
    }

    @Test("a candidate gets the health check only; the address in use keeps working")
    func candidateHealthOnly() {
        var configuration = Self.base
        configuration.candidateOrigin = "https://" + Self.candidate
        func verdict(_ method: String, _ target: String, host: String) -> String {
            Self.verdict(method, target, host: host, configuration: configuration)
        }
        let candidate = Self.candidate, health = Self.health, prefix = Self.prefix
        #expect(verdict("GET", health, host: candidate) == "health", "candidate health")
        #expect(verdict("GET", health, host: candidate + ":443") == "health", "candidate health :443")
        #expect(verdict("GET", health, host: "Quiet-River-1234.trycloudflare.com") == "health",
                "Host is case-insensitive")
        for (method, target) in Self.routes {
            #expect(verdict(method, target, host: candidate) == "421", "candidate \(target)")
        }
        #expect(verdict("POST", health, host: candidate) == "404", "health still needs GET")
        #expect(verdict("GET", prefix + "/health", host: candidate) == "404", "health still needs a nonce")
        #expect(verdict("GET", "/r/wrong/health?nonce=abc", host: candidate) == "404",
                "the secret path still comes first")
        #expect(verdict("GET", health, host: "other.trycloudflare.com") == "421", "only the candidate")
        // The address in use keeps working; loopback (tunnels that rewrite Host) too.
        #expect(verdict("POST", prefix + "/mcp", host: "my-mac.tail1234.ts.net") == "mcp", "in use, mcp")
        #expect(verdict("POST", prefix + "/mcp", host: "127.0.0.1:47616") == "mcp", "loopback, mcp")
    }

    @Test("a candidate with a port; the MCP URL and OAuth never use the candidate")
    func candidateWithPort() {
        var configuration = Self.base
        configuration.candidateOrigin = "https://my-mac.tail1234.ts.net:8443"
        func verdict(_ method: String, _ target: String, host: String) -> String {
            Self.verdict(method, target, host: host, configuration: configuration)
        }
        // Port rules as for the address: a candidate with a port.
        #expect(verdict("GET", Self.health, host: "my-mac.tail1234.ts.net:8443") == "health", "candidate with a port")
        #expect(verdict("GET", Self.health, host: "my-mac.tail1234.ts.net") == "health",
                "…the address in use, by itself")
        #expect(verdict("POST", Self.prefix + "/mcp", host: "my-mac.tail1234.ts.net:8443") == "421",
                "candidate port, mcp")
        #expect(configuration.mcpURL == "https://my-mac.tail1234.ts.net" + Self.prefix + "/mcp"
            && configuration.oauthContext?.publicOrigin == "https://my-mac.tail1234.ts.net",
                "the MCP URL and OAuth never use the candidate")
    }

    @Test("the health route reports the tunnel its headers point to")
    func healthTunnel() throws {
        func health(_ headers: KeyValuePairs<String, String>) throws -> (String, [String], TunnelProvider?) {
            var all: [(String, String)] = [("Host", "my-mac.tail1234.ts.net")]
            all += headers.map { ($0.key, $0.value) }
            var text = "GET \(Self.health) HTTP/1.1\r\n"
            for (name, value) in all { text += "\(name): \(value)\r\n" }
            let request = try #require(Self.parse(text + "\r\n"))
            guard case .health(let nonce, let names, let tunnel) = RemoteHTTPGate.check(request,
                                                                                    configuration: Self.base) else {
                Issue.record("not the health route")
                return ("", [], nil)
            }
            return (nonce, names, tunnel)
        }
        let funnel = try health(["Tailscale-Funnel-Request": "?1", "X-Forwarded-For": "203.0.113.9"])
        #expect(funnel.0 == "abc")
        #expect(funnel.1 == ["tailscale-funnel-request", "x-forwarded-for"])
        #expect(funnel.2 == .tailscaleFunnel)
        #expect(try health(["CF-Ray": "1", "X-Forwarded-Host": "quiet-river-1234.trycloudflare.com"]).2
            == .cloudflareQuick)
        #expect(try health(["CF-Ray": "1"]).2 == .cloudflareTunnel)
        #expect(try health(["X-Forwarded-Host": "my-mac-example.ngrok-free.app"]).2 == .ngrok)
        #expect(try health(["X-Forwarded-For": "203.0.113.9"]).2 == .other)
        let direct = try health([:])
        #expect(direct.1.isEmpty && direct.2 == nil)
    }
}

/// The reachability test's answer: success only with this app's nonce; failures typed for the
/// app to word.
@Suite("Remote probe")
struct RemoteProbeTests {
    static let url = URL(string: "https://my-mac.tail1234.ts.net/r/q7Zk2vN4bXwP9sL1mT6hYa/health")!

    static func response(_ status: Int) -> HTTPURLResponse? {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
    }

    static func body(_ object: [String: String]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    @Test("200 with this app's nonce is success, with the tunnel the health route saw")
    func success() {
        let named = RemoteProbe.result(data: Self.body(["nonce": "abc", "tunnel": "Cloudflare quick tunnel"]),
                                       response: Self.response(200), error: nil, nonce: "abc", rtt: 0.25)
        #expect(named == .success(RemoteProbeResult(rtt: 0.25, tunnel: .cloudflareQuick)))
        #expect(named == .success(RemoteProbeResult(rtt: 0.25, tunnel: TunnelProvider(wireName: "Cloudflare quick tunnel"))))
        for provider in TunnelProvider.allCases {
            let result = RemoteProbe.result(data: Self.body(["nonce": "abc", "tunnel": provider.wireName]),
                                            response: Self.response(200), error: nil, nonce: "abc", rtt: 1)
            #expect(result == .success(RemoteProbeResult(rtt: 1, tunnel: provider)), "\(provider.wireName)")
        }
        let direct = RemoteProbe.result(data: Self.body(["nonce": "abc"]), response: Self.response(200), error: nil,
                                        nonce: "abc", rtt: 1)
        #expect(direct == .success(RemoteProbeResult(rtt: 1, tunnel: nil)), "no tunnel headers")
        let unknown = RemoteProbe.result(data: Self.body(["nonce": "abc", "tunnel": "warp"]),
                                         response: Self.response(200), error: nil, nonce: "abc", rtt: 1)
        #expect(unknown == .success(RemoteProbeResult(rtt: 1, tunnel: nil)), "an unknown wire name")
    }

    @Test("anything else answering is wrongHost (421), notThisApp or noAnswer")
    func otherAnswers() {
        func result(_ data: Data?, _ status: Int?) -> Result<RemoteProbeResult, RemoteProbeFailure> {
            RemoteProbe.result(data: data, response: status.flatMap(Self.response), error: nil, nonce: "abc", rtt: 1)
        }
        #expect(result(Self.body(["nonce": "other"]), 200) == .failure(.notThisApp(status: 200)), "another nonce")
        #expect(result(Data("<html>".utf8), 200) == .failure(.notThisApp(status: 200)), "not JSON")
        #expect(result(nil, 200) == .failure(.notThisApp(status: 200)), "no body")
        #expect(result(Self.body(["nonce": "abc"]), 421) == .failure(.wrongHost), "421")
        #expect(result(nil, 404) == .failure(.notThisApp(status: 404)), "404")
        #expect(result(Self.body(["nonce": "abc"]), 502) == .failure(.notThisApp(status: 502)), "502")
        #expect(result(nil, nil) == .failure(.noAnswer), "nothing")
        // A URL error wins over whatever else arrived.
        let failed = RemoteProbe.result(data: Self.body(["nonce": "abc"]), response: Self.response(200),
                                        error: URLError(.timedOut), nonce: "abc", rtt: 10)
        #expect(failed == .failure(.timedOut))
    }

    @Test("URL errors by code")
    func urlErrors() {
        let cases: [(URLError.Code, RemoteProbeFailure)] = [
            (.timedOut, .timedOut),
            (.cannotFindHost, .cannotFindHost), (.dnsLookupFailed, .cannotFindHost),
            (.cannotConnectToHost, .connectionRefused),
            (.secureConnectionFailed, .certificateRejected), (.serverCertificateUntrusted, .certificateRejected),
            (.serverCertificateHasBadDate, .certificateRejected),
            (.networkConnectionLost, .requestFailed(code: URLError.Code.networkConnectionLost.rawValue)),
            (.notConnectedToInternet, .requestFailed(code: -1009)),
        ]
        for (code, expected) in cases {
            #expect(RemoteProbe.failure(URLError(code)) == expected, "\(code.rawValue)")
        }
    }

    @Test("no public address: noAddress, without a request")
    @MainActor
    func noAddress() async {
        let configuration = RemoteConfiguration(secret: "q7Zk2vN4bXwP9sL1mT6hYa", publicOrigin: nil, port: 47616)
        let result = await withCheckedContinuation { continuation in
            RemoteProbe.test(configuration, nonces: RemoteNonces()) { continuation.resume(returning: $0) }
        }
        #expect(result == .failure(.noAddress))
    }
}

/// What an app hands the remote tier: its words, its `User-Agent`.
@Suite("Remote seams")
struct RemoteSeamsTests {
    @Test("the standard texts for EK Bridge are EK Bridge's own words")
    func standardTexts() {
        let texts = RemoteTexts.standard(displayName: "EK Bridge")
        #expect(texts.unauthorized == "EK Bridge doesn't recognize this credential. Use the client's remote token "
            + "or connect the app again from the client's Cloud section.")
        #expect(texts.originRefused == "Requests from web pages aren't accepted.")
        #expect(texts.pairingClosed == "In EK Bridge on your Mac, open the client you want to use and choose "
            + "Connect a Cloud App. Then start connecting again from the app.")
        #expect(texts.pairingPrompt == "Check that EK Bridge on your Mac shows this code, then choose Allow there.")
        #expect(texts.agentLabel == "Client")
        #expect(texts.declined == "The connection was declined in EK Bridge.")
        #expect(texts.redirectNotRegistered == "The redirect_uri doesn’t exactly match one the app registered, so "
            + "EK Bridge won’t send you there.")
        #expect(texts.metadataUnusable == "EK Bridge couldn’t use the app’s metadata document.")
        #expect(texts.setUpForAnotherTitle == "This app was set up for another client")
        #expect(texts.setUpForAnother == "Pairing is open for a different client in EK Bridge. Open the client this "
            + "app was set up for and choose Connect a Cloud App.")
        #expect(texts.cloudAccessOffPage == "This client no longer allows cloud access. Turn it on in EK Bridge and "
            + "connect again.")
        #expect(texts.cloudAccessOff == "This client no longer allows cloud access.")
        #expect(texts.tooManyConnections == "Too many connected apps. Revoke some in EK Bridge first.")
        #expect(texts.registrationClosed == "Pairing isn't open. In EK Bridge on the Mac, open the client and choose "
            + "Connect a Cloud App.")
        #expect(texts.storeUnavailable == "EK Bridge can’t read its list of connected apps, so it isn’t accepting "
            + "new ones. Check the app on your Mac.")
        // Without texts, a configuration uses the standard ones for its display name.
        let configuration = RemoteBridgeConfiguration(
            identity: BridgeIdentity(displayName: "EK Bridge", bundleID: "com.example.ekbridge",
                                     dataFolder: FileManager.default.temporaryDirectory, version: "0.11.2"),
            defaultPort: 47616, remoteTokenPrefix: "ekb_mcpr_v1_", accessTokenPrefix: "ekb_oat_v1_",
            refreshTokenPrefix: "ekb_ort_v1_", clientSecretPrefix: "ekb_ocs_v1_", scope: "calendar",
            userAgentProduct: "EKBridge", storeDirectory: FileManager.default.temporaryDirectory)
        #expect(configuration.texts == texts)
        #expect(RemoteTexts.standard(displayName: "Funes Vault", agent: "agent").agentLabel == "Agent")
    }

    @Test("User-Agent: product/version, version 0 unless plain ASCII")
    func userAgent() {
        func agent(_ version: String) -> String {
            EKBridgeRemote.configuration(storeDirectory: FileManager.default.temporaryDirectory, version: version)
                .userAgent
        }
        #expect(agent("0.11.2") == "EKBridge/0.11.2")
        #expect(agent("–") == "EKBridge/0", "unbundled builds")
        #expect(agent("0.11.2β") == "EKBridge/0", "non-ASCII")
        #expect(agent("1.0 (3)") == "EKBridge/0", "spaces and parentheses")
        #expect(agent("") == "EKBridge/0", "empty")
    }

    @Test("the remote 401 carries the app's words and the OAuth challenge once there's an address")
    @MainActor
    func unauthorized() {
        let configuration = EKBridgeRemote.configuration(storeDirectory: FileManager.default.temporaryDirectory)
        let secret = "q7Zk2vN4bXwP9sL1mT6hYa"
        let withAddress = RemoteMCPService.unauthorized(
            RemoteConfiguration(secret: secret, publicOrigin: "https://my-mac.tail1234.ts.net", port: 47616),
            configuration: configuration)
        #expect(withAddress.status == 401)
        #expect(header(withAddress, "www-authenticate") == "Bearer resource_metadata=\"https://my-mac.tail1234.ts.net"
            + "/.well-known/oauth-protected-resource/r/\(secret)/mcp\", scope=\"calendar\"")
        let error = json(withAddress)["error"] as? [String: Any]
        #expect(error?["message"] as? String == configuration.texts.unauthorized)
        #expect(error?["code"] as? Int == -32001)
        let noAddress = RemoteMCPService.unauthorized(RemoteConfiguration(secret: secret, publicOrigin: nil,
                                                                          port: 47616),
                                                      configuration: configuration)
        #expect(header(noAddress, "www-authenticate") == "Bearer realm=\"EK Bridge\"")
    }
}
