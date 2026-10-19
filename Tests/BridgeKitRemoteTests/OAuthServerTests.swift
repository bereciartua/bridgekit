import BridgeKitCore
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import BridgeKitRemote

/// EK Bridge's Remote Access values, so the expectations are the ones EK Bridge had before the
/// extraction (its prefixes, its "calendar" scope and its "client" wording).
enum EKBridgeRemote {
    static func configuration(storeDirectory: URL, version: String = "0.11.2") -> RemoteBridgeConfiguration {
        RemoteBridgeConfiguration(
            identity: BridgeIdentity(displayName: "EK Bridge", bundleID: "com.example.ekbridge",
                                     dataFolder: storeDirectory, version: version),
            defaultPort: 47616, remoteTokenPrefix: "ekb_mcpr_v1_", accessTokenPrefix: "ekb_oat_v1_",
            refreshTokenPrefix: "ekb_ort_v1_", clientSecretPrefix: "ekb_ocs_v1_", scope: "calendar",
            userAgentProduct: "EKBridge", storeDirectory: storeDirectory,
            texts: .standard(displayName: "EK Bridge"))
    }
}

/// A private (0700) folder per test, removed afterwards.
final class ScratchFolder {
    let root: URL

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridgekit-\(name)-\(UUID().uuidString)")
        guard mkdir(root.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    deinit {
        chmod(root.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }
}

private let clientA = "0B0F2C1E-8C55-4C5B-9F59-3A2C1E5D7A11"
private let clientB = "7E2D1C3B-4A59-4F6E-8D7C-6B5A4F3E2D1C"
private let secret = "AbCdEfGhIjKlMnOpQrStUv"
private let prefix = "/r/" + secret
private let origin = "https://my-mac.tail1234.ts.net"
private let issuer = origin + prefix
private let resource = issuer + "/mcp"
private let context = OAuthContext(publicOrigin: origin, secretPrefix: prefix)
private let cimdURL = "https://claude.ai/oauth/mcp-oauth-client-metadata"
private let redirectURI = "https://claude.ai/api/mcp/auth_callback"
private let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk-abc"

/// Discovery, pairing, CIMD, DCR, PKCE, codes, tokens, refresh rotation, revocation, confidential
/// clients, escaping, persistence and fail-closed storage of the OAuth authorization server.
@MainActor
@Suite("OAuth server")
struct OAuthServerTests {
    @MainActor
    final class FakeFetcher: CIMDFetching {
        var documents = [String: Result<ClientMetadata, CIMDError>]()
        var fetched = [URL]()
        /// When set, completions wait in `held` until the test releases them.
        var hold = false
        var held = [() -> Void]()

        func fetch(_ url: URL, completion: @escaping (Result<ClientMetadata, CIMDError>) -> Void) {
            fetched.append(url)
            let result = documents[url.absoluteString] ?? .failure(.httpStatus(404))
            if hold { held.append { completion(result) } } else { completion(result) }
        }
    }

    @MainActor
    final class Harness {
        let scratch: ScratchFolder
        let directory: URL
        let fetcher = FakeFetcher()
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        var allowed: Set<String> = [clientA, clientB]
        var requested = [PairingRequest]()
        var pairingChanges = 0
        var changedClients = [String]()
        var server: OAuthServer!

        /// A fresh store with claude.ai's metadata document available.
        static func fresh(subfolder: String = "store") throws -> Harness {
            let harness = try Harness(subfolder: subfolder)
            harness.fetcher.documents[cimdURL] = .success(ClientMetadata(
                clientID: cimdURL, clientName: "Claude", redirectURIs: [redirectURI],
                clientURI: "https://claude.ai"))
            return harness
        }

        init(subfolder: String) throws {
            scratch = try ScratchFolder("oauth-test")
            directory = scratch.root.appendingPathComponent(subfolder)
            restart()
        }

        func restart() {
            server = OAuthServer(configuration: EKBridgeRemote.configuration(storeDirectory: directory),
                                 fetcher: fetcher,
                                 now: { [unowned self] in self.clock },
                                 agentAllowed: { [unowned self] in self.allowed.contains($0) },
                                 agentName: { $0 == clientA ? "claude.ai (Alex)" : "Other client" },
                                 schedule: { _, _ in })
            server.pairingRequested = { [unowned self] in self.requested.append($0) }
            server.pairingChanged = { [unowned self] in self.pairingChanges += 1 }
            server.connectionsChanged = { [unowned self] in self.changedClients.append($0) }
        }

        func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

        /// The reply, which must arrive synchronously (the fake fetcher answers at once unless held).
        func send(_ request: HTTPRequest, sourceLocation: SourceLocation = #_sourceLocation) -> HTTPResponse {
            var reply: HTTPResponse?
            let handled = server.handle(request, context: context) { reply = $0 }
            #expect(handled, "unhandled \(request.target)", sourceLocation: sourceLocation)
            guard let reply else {
                Issue.record("no synchronous reply to \(request.target)", sourceLocation: sourceLocation)
                return HTTPResponse(status: -1)
            }
            return reply
        }

        func get(_ path: String, _ query: [(String, String)] = []) -> HTTPResponse {
            send(OAuthServerTests.request("GET", path + encodeQuery(query)))
        }

        func post(_ path: String, _ form: [(String, String)],
                  headers: [(String, String)] = []) -> HTTPResponse {
            send(OAuthServerTests.request("POST", path, body: Data(encodeQuery(form).dropFirst().utf8),
                                          headers: [("content-type", "application/x-www-form-urlencoded")] + headers))
        }

        func status(_ id: UUID) -> HTTPResponse {
            get(prefix + "/oauth/authorize/status", [("request", id.uuidString)])
        }

        func authorize(clientID: String = cimdURL, redirect: String = redirectURI,
                       challenge: String? = nil, omit: Set<String> = [],
                       extra: [(String, String)] = []) -> HTTPResponse {
            let base: [(String, String)] = [
                ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirect),
                ("code_challenge", challenge ?? s256(verifier)), ("code_challenge_method", "S256"),
                ("state", "st-1"), ("resource", resource), ("scope", "calendar"),
            ]
            return get(prefix + "/oauth/authorize", base.filter { !omit.contains($0.0) } + extra)
        }

        /// Authorize → Allow → the code from the redirect the browser page receives.
        func pairedCode(clientID: String = cimdURL, redirect: String = redirectURI) throws -> String {
            let page = authorize(clientID: clientID, redirect: redirect)
            try #require(page.status == 200, "authorize \(page.status) \(text(page))")
            let pending = try #require(server.pendingPairings.last)
            server.answerPairing(pending.id, allow: true)
            let status = json(get(prefix + "/oauth/authorize/status", [("request", pending.id.uuidString)]))
            let items = queryItems(try #require(status["redirect"] as? String))
            try #require(items["state"] == "st-1" && items["iss"] == issuer)
            return try #require(items["code"])
        }

        func exchange(_ code: String, clientID: String = cimdURL, verifier: String = verifier,
                      redirect: String = redirectURI) -> HTTPResponse {
            post(prefix + "/oauth/token", [
                ("grant_type", "authorization_code"), ("code", code), ("client_id", clientID),
                ("redirect_uri", redirect), ("code_verifier", verifier), ("resource", resource),
            ])
        }

        func refresh(_ token: String, clientID: String = cimdURL) -> HTTPResponse {
            post(prefix + "/oauth/token", [
                ("grant_type", "refresh_token"), ("refresh_token", token), ("client_id", clientID),
            ])
        }

        /// A full connection for client A: (access, refresh).
        func connect(clientID: String = cimdURL, redirect: String = redirectURI) throws -> (String, String) {
            openWindow()
            let response = exchange(try pairedCode(clientID: clientID, redirect: redirect), clientID: clientID,
                                    redirect: redirect)
            try #require(response.status == 200, "\(text(response))")
            let body = json(response)
            return (try #require(body["access_token"] as? String), try #require(body["refresh_token"] as? String))
        }

        func openWindow(_ client: String = clientA) { server.openPairing(clientID: client) }

        func codeFromStatus(_ id: UUID) throws -> String {
            let status = json(get(prefix + "/oauth/authorize/status", [("request", id.uuidString)]))
            let redirect = try #require(status["redirect"] as? String)
            return try #require(queryItems(redirect)["code"])
        }

        var storeFile: URL { directory.appendingPathComponent("remote-connections.json") }
    }

    // MARK: Discovery

    @Test("protected-resource and authorization-server metadata, and the 401 challenge")
    func discoveryDocuments() throws {
        let h = try Harness.fresh()
        let prm = h.get("/.well-known/oauth-protected-resource" + prefix + "/mcp")
        #expect(prm.status == 200 && header(prm, "content-type") == "application/json")
        #expect(header(prm, "cache-control") == "no-store")
        let prmBody = json(prm)
        #expect(Set(prmBody.keys) == ["resource", "authorization_servers", "scopes_supported",
                                      "bearer_methods_supported"])
        #expect(prmBody["resource"] as? String == resource)
        #expect(prmBody["authorization_servers"] as? [String] == [issuer])
        #expect(prmBody["scopes_supported"] as? [String] == ["calendar"])
        #expect(prmBody["bearer_methods_supported"] as? [String] == ["header"])
        #expect(text(prm).contains("\"https://my-mac.tail1234.ts.net/r/"), "slashes unescaped")
        let paths = ["/.well-known/oauth-authorization-server" + prefix,
                     "/.well-known/openid-configuration" + prefix,
                     prefix + "/.well-known/openid-configuration"]
        for path in paths {
            let body = json(h.get(path))
            #expect(Set(body.keys) == [
                "issuer", "authorization_endpoint", "token_endpoint", "registration_endpoint",
                "revocation_endpoint", "response_types_supported", "grant_types_supported",
                "code_challenge_methods_supported", "token_endpoint_auth_methods_supported",
                "client_id_metadata_document_supported", "authorization_response_iss_parameter_supported",
                "scopes_supported"], "\(path)")
            #expect(body["issuer"] as? String == issuer)
            #expect(body["authorization_endpoint"] as? String == issuer + "/oauth/authorize")
            #expect(body["token_endpoint"] as? String == issuer + "/oauth/token")
            #expect(body["registration_endpoint"] as? String == issuer + "/oauth/register")
            #expect(body["revocation_endpoint"] as? String == issuer + "/oauth/revoke")
            #expect(body["response_types_supported"] as? [String] == ["code"])
            #expect(body["grant_types_supported"] as? [String] == ["authorization_code", "refresh_token"])
            #expect(body["code_challenge_methods_supported"] as? [String] == ["S256"])
            #expect(body["token_endpoint_auth_methods_supported"] as? [String] == ["none"])
            #expect(body["client_id_metadata_document_supported"] as? Bool == true)
            #expect(body["authorization_response_iss_parameter_supported"] as? Bool == true)
            #expect(body["scopes_supported"] as? [String] == ["calendar"])
        }
        #expect(h.server.scope == "calendar")
        #expect(OAuthServer.challenge(context, scope: h.server.scope) == "Bearer resource_metadata=\"" + origin
            + "/.well-known/oauth-protected-resource" + prefix + "/mcp\", scope=\"calendar\"")
        #expect(context.resourceMetadataURL == origin + "/.well-known/oauth-protected-resource" + prefix + "/mcp")
    }

    @Test("never at root paths, traversal, encodings, case variants, another or a malformed secret")
    func exactRoutesOnly() throws {
        let h = try Harness.fresh()
        for path in ["/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server",
                     "/.well-known/openid-configuration", "/oauth/authorize", "/oauth/token",
                     prefix + "/oauth/../oauth/token", prefix + "%2Foauth%2Ftoken", prefix + "/oauth/token/",
                     prefix + "//oauth/token", prefix.uppercased() + "/oauth/token",
                     "/r/AbCdEfGhIjKlMnOpQrStUw/oauth/token", prefix + "/mcp", prefix + "/oauth/authorize/"] {
            var called = false
            #expect(!h.server.handle(Self.request("GET", path), context: context) { _ in called = true }, "\(path)")
            #expect(!called, "\(path)")
        }
        // A malformed secret prefix (empty, short) never exposes anything.
        for bad in ["", "/r/short", "/r/AbCdEfGhIjKlMnOpQrSt/v", "/x/AbCdEfGhIjKlMnOpQrStUv"] {
            let badContext = OAuthContext(publicOrigin: origin, secretPrefix: bad)
            #expect(!h.server.handle(Self.request("GET", "/.well-known/oauth-authorization-server" + bad),
                                     context: badContext) { _ in }, "\(bad)")
            #expect(!h.server.handle(Self.request("POST", bad + "/oauth/token"), context: badContext) { _ in },
                    "\(bad)")
        }
    }

    @Test("wrong methods are 405 with Allow, and nothing is CORS")
    func methodsAndCORS() throws {
        let h = try Harness.fresh()
        let wrongMethod = h.send(Self.request("POST", "/.well-known/oauth-authorization-server" + prefix))
        #expect(wrongMethod.status == 405 && header(wrongMethod, "allow") == "GET")
        let getToken = h.get(prefix + "/oauth/token")
        #expect(getToken.status == 405 && header(getToken, "allow") == "POST")
        #expect(h.send(Self.request("DELETE", prefix + "/oauth/revoke")).status == 405)
        #expect(h.send(Self.request("POST", prefix + "/oauth/authorize")).status == 405)
        #expect(h.send(Self.request("OPTIONS", prefix + "/oauth/register")).status == 405)
        // Never CORS, whatever the Origin.
        let withOrigin = h.send(Self.request("GET", "/.well-known/oauth-authorization-server" + prefix,
                                             headers: [("origin", "https://evil.example")]))
        #expect(!withOrigin.headers.contains { $0.name.lowercased().hasPrefix("access-control-") })
    }

    // MARK: Authorization

    @Test("outside a pairing window: a page, no fetch and no prompt")
    func authorizeOutsideWindow() throws {
        let h = try Harness.fresh()
        let page = h.authorize()
        #expect(page.status == 403 && text(page).contains("Pairing isn’t open"))
        #expect(text(page).contains("choose Connect a Cloud App"))
        #expect(h.fetcher.fetched.isEmpty, "nothing is fetched outside a window")
        #expect(h.requested.isEmpty && h.server.pendingPairings.isEmpty)
        #expect(header(page, "location") == nil)
        checkPageHeaders(page)
        // Closing ends it too.
        h.openWindow()
        #expect(h.server.pairingClientID == clientA)
        h.server.closePairing()
        #expect(h.server.pairingClientID == nil && h.authorize().status == 403)
    }

    @Test("a CIMD client's request reaches the Mac with its code, name and return host")
    func cimdPairingRequest() throws {
        let h = try Harness.fresh()
        h.openWindow()
        #expect(h.server.pairingClientID == clientA)
        #expect(h.server.pairingExpiresAt == h.clock.addingTimeInterval(600))
        let page = h.authorize()
        #expect(page.status == 200, "\(text(page))")
        checkPageHeaders(page)
        #expect(h.fetcher.fetched.map(\.absoluteString) == [cimdURL])
        #expect(h.requested.count == 1 && h.server.pendingPairings == h.requested)
        let pairing = try #require(h.requested.first)
        #expect(pairing.clientID == clientA && pairing.appName == "Claude" && pairing.appURL == cimdURL)
        #expect(pairing.redirectHost == "claude.ai")
        #expect(pairing.expiresAt == h.clock.addingTimeInterval(300))
        let digits = pairing.code.split(separator: " ")
        #expect(digits.count == 2 && digits.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) })
        let html = text(page)
        #expect(html.contains(pairing.code) && html.contains("claude.ai (Alex)"))
        #expect(html.contains("data-request=\"\(pairing.id.uuidString.lowercased())\""))
        #expect(html.contains("authorize/status?request="))
        let status = json(h.get(prefix + "/oauth/authorize/status", [("request", pairing.id.uuidString)]))
        #expect(status["status"] as? String == "pending" && status["redirect"] == nil)
        #expect(json(h.status(UUID()))["status"] as? String == "expired")
    }

    @Test("unusable documents and unregistered redirect URIs never redirect or prompt")
    func cimdRefusals() throws {
        let h = try Harness.fresh()
        h.openWindow()
        #expect(h.authorize().status == 200)
        // The document must name the URL it came from; unknown redirect URIs never redirect.
        let other = "https://evil.example/client.json"
        h.fetcher.documents[other] = .success(ClientMetadata(
            clientID: cimdURL, clientName: "Claude", redirectURIs: ["https://evil.example/cb"], clientURI: nil))
        let mismatch = h.authorize(clientID: other, redirect: "https://evil.example/cb")
        #expect(mismatch.status == 400 && header(mismatch, "location") == nil)
        let unknownRedirect = h.authorize(redirect: "https://claude.ai/api/mcp/other")
        #expect(unknownRedirect.status == 400 && header(unknownRedirect, "location") == nil)
        #expect(text(unknownRedirect).contains("return address"))
        let prefixRedirect = h.authorize(redirect: redirectURI + "/x")
        #expect(prefixRedirect.status == 400 && header(prefixRedirect, "location") == nil)
        let failed = h.authorize(clientID: "https://unreachable.example/client.json",
                                 redirect: "https://unreachable.example/cb")
        #expect(failed.status == 502 && header(failed, "location") == nil)
        #expect(text(failed).contains("Its server answered with HTTP status 404."), "\(text(failed))")
        let unknownClient = h.authorize(clientID: "dcr_unknown")
        #expect(unknownClient.status == 400 && header(unknownClient, "location") == nil)
        let missing = h.authorize(omit: ["redirect_uri"])
        #expect(missing.status == 400 && header(missing, "location") == nil)
        let duplicated = h.authorize(extra: [("client_id", cimdURL)])
        #expect(duplicated.status == 400 && header(duplicated, "location") == nil)
        // A document can't smuggle a script URL in as a redirect URI.
        let scripted = "https://scripted.example/client.json"
        h.fetcher.documents[scripted] = .success(ClientMetadata(
            clientID: scripted, clientName: "X", redirectURIs: ["javascript:alert(1)"], clientURI: nil))
        #expect(h.authorize(clientID: scripted, redirect: "javascript:alert(1)").status == 400)
        #expect(h.requested.count == 1, "no failed request reaches the Mac")
    }

    @Test("the window closing during the fetch: no prompt; a retrying app doesn't stack prompts")
    func cimdWindowClosingAndRetries() throws {
        let h = try Harness.fresh()
        h.openWindow()
        #expect(h.authorize().status == 200)
        // The window closing while the document is fetched: no prompt.
        h.fetcher.hold = true
        var reply: HTTPResponse?
        _ = h.server.handle(Self.request("GET", prefix + "/oauth/authorize" + encodeQuery([
            ("response_type", "code"), ("client_id", cimdURL), ("redirect_uri", redirectURI),
            ("code_challenge", s256(verifier)), ("code_challenge_method", "S256"),
        ])), context: context) { reply = $0 }
        #expect(reply == nil)
        h.server.closePairing()
        try #require(!h.fetcher.held.isEmpty)
        h.fetcher.held.removeFirst()()
        #expect(reply?.status == 403 && h.requested.count == 1)
        h.fetcher.hold = false

        // A retrying app doesn't stack prompts.
        h.openWindow()
        for _ in 0..<5 { #expect(h.authorize().status == 200) }
        #expect(h.server.pendingPairings.count == OAuthServer.maxPendingPairings)
    }

    @Test("errors after the client is trusted go back to the app, with state and iss")
    func authorizeErrors() throws {
        let h = try Harness.fresh()
        h.openWindow()
        func errorRedirect(_ response: HTTPResponse,
                           sourceLocation: SourceLocation = #_sourceLocation) -> [String: String] {
            #expect(response.status == 302, "\(response.status) \(text(response))", sourceLocation: sourceLocation)
            let location = header(response, "location") ?? ""
            #expect(location.hasPrefix(redirectURI + "?"), sourceLocation: sourceLocation)
            let items = queryItems(location)
            #expect(items["state"] == "st-1" && items["iss"] == issuer, sourceLocation: sourceLocation)
            return items
        }
        let token = [("response_type", "token")]
        #expect(errorRedirect(h.authorize(extra: token))["error"] == "invalid_request")
        #expect(errorRedirect(h.authorize(omit: ["response_type"], extra: token))["error"]
            == "unsupported_response_type")
        #expect(errorRedirect(h.authorize(omit: ["resource"], extra: [("resource", "https://other.example/mcp")]))[
            "error"] == "invalid_target")
        #expect(errorRedirect(h.authorize(omit: ["resource"], extra: [("resource", issuer)]))["error"]
            == "invalid_target")
        #expect(h.requested.isEmpty)
        // Uppercase scheme and host are the same resource; no resource at all binds to ours.
        #expect(h.authorize(omit: ["resource"],
                            extra: [("resource", "HTTPS://MY-MAC.tail1234.ts.net" + prefix + "/mcp")]).status == 200)
        #expect(h.authorize(omit: ["resource", "state"]).status == 200)
        // No state: none echoed.
        let noState = h.authorize(omit: ["state", "response_type"], extra: [("response_type", "id_token")])
        let noStateLocation = try #require(header(noState, "location"))
        #expect(queryItems(noStateLocation)["state"] == nil)
        // Cloud access turned off meanwhile: a page, no prompt.
        h.allowed = []
        let off = h.authorize()
        #expect(off.status == 403 && header(off, "location") == nil && h.requested.count == 2)
    }

    @Test("PKCE S256 is required and checked")
    func pkce() throws {
        let h = try Harness.fresh()
        h.openWindow()
        func error(_ response: HTTPResponse) -> String? {
            header(response, "location").flatMap { queryItems($0)["error"] }
        }
        #expect(error(h.authorize(omit: ["code_challenge"])) == "invalid_request")
        #expect(error(h.authorize(omit: ["code_challenge_method"])) == "invalid_request")
        #expect(error(h.authorize(omit: ["code_challenge_method"], extra: [("code_challenge_method", "plain")]))
            == "invalid_request")
        #expect(error(h.authorize(challenge: verifier)) == "invalid_request", "not a S256 value")
        #expect(h.requested.isEmpty)
        // Wrong verifier fails, and the code is spent.
        let code = try h.pairedCode()
        let wrong = h.exchange(code, verifier: String(repeating: "a", count: 43))
        #expect(wrong.status == 400 && json(wrong)["error"] as? String == "invalid_grant")
        #expect(json(h.exchange(code))["error"] as? String == "invalid_grant")
        // Missing verifier.
        h.openWindow()
        let second = try h.pairedCode()
        let missing = h.post(prefix + "/oauth/token", [
            ("grant_type", "authorization_code"), ("code", second), ("client_id", cimdURL),
            ("redirect_uri", redirectURI)])
        #expect(json(missing)["error"] as? String == "invalid_request")
        // Success with the right verifier.
        h.openWindow()
        let third = h.exchange(try h.pairedCode())
        #expect(third.status == 200)
        #expect(OAuthServer.s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 appendix B")
    }

    // MARK: Codes and tokens

    @Test("codes: single use, 60 s, bound to client, redirect URI and resource")
    func codes() throws {
        let h = try Harness.fresh()
        // Single use: a replay fails and revokes what the first exchange produced.
        h.openWindow()
        #expect(h.server.pairingClientID == clientA)
        let code = try h.pairedCode()
        #expect(h.server.pairingClientID == nil, "Allow closes the window")
        let first = h.exchange(code)
        #expect(first.status == 200)
        let access = try #require(json(first)["access_token"] as? String)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        let replay = h.exchange(code)
        #expect(replay.status == 400 && json(replay)["error"] as? String == "invalid_grant")
        #expect(h.server.authenticate(accessToken: access, resource: resource) == nil)
        #expect(h.server.connections(clientID: clientA).isEmpty)
        // 60 s lifetime.
        h.openWindow()
        let late = try h.pairedCode()
        h.advance(61)
        #expect(json(h.exchange(late))["error"] as? String == "invalid_grant")
        // Bound to client_id and redirect_uri.
        h.openWindow()
        #expect(json(h.exchange(try h.pairedCode(), clientID: "https://other.example/c.json"))["error"]
            as? String == "invalid_grant")
        h.openWindow()
        #expect(json(h.exchange(try h.pairedCode(), redirect: redirectURI + "?x=1"))["error"]
            as? String == "invalid_grant")
        // Bound to the resource.
        h.openWindow()
        let resourceCode = try h.pairedCode()
        let wrongResource = h.post(prefix + "/oauth/token", [
            ("grant_type", "authorization_code"), ("code", resourceCode), ("client_id", cimdURL),
            ("redirect_uri", redirectURI), ("code_verifier", verifier),
            ("resource", "https://x.example/mcp")])
        #expect(json(wrongResource)["error"] as? String == "invalid_target")
        // Unknown code.
        #expect(json(h.exchange("nope"))["error"] as? String == "invalid_grant")
    }

    @Test("Deny, and Allow after cloud access went off, send access_denied")
    func denials() throws {
        let h = try Harness.fresh()
        // Deny sends access_denied with state and iss.
        h.openWindow()
        #expect(h.authorize().status == 200)
        let pending = try #require(h.server.pendingPairings.first)
        h.server.answerPairing(pending.id, allow: false)
        #expect(h.server.pendingPairings.isEmpty && h.server.pairingClientID == clientA)
        let denied = json(h.get(prefix + "/oauth/authorize/status", [("request", pending.id.uuidString)]))
        let items = queryItems(try #require(denied["redirect"] as? String))
        #expect(items["error"] == "access_denied" && items["state"] == "st-1" && items["iss"] == issuer)
        #expect(items["code"] == nil)
        // A client that lost cloud access before Allow gets a denial, not a code.
        #expect(h.authorize().status == 200)
        let revoked = try #require(h.server.pendingPairings.first)
        h.allowed = []
        h.server.answerPairing(revoked.id, allow: true)
        let answer = json(h.get(prefix + "/oauth/authorize/status", [("request", revoked.id.uuidString)]))
        let answerRedirect = try #require(answer["redirect"] as? String)
        #expect(queryItems(answerRedirect)["error"] == "access_denied")
    }

    @Test("token response, audience check, cloud access and the one-hour lifetime")
    func tokens() throws {
        let h = try Harness.fresh()
        h.openWindow()
        let response = h.exchange(try h.pairedCode())
        #expect(response.status == 200)
        #expect(header(response, "cache-control") == "no-store")
        #expect(header(response, "pragma") == "no-cache")
        let body = json(response)
        #expect(Set(body.keys) == ["access_token", "token_type", "expires_in", "refresh_token", "scope"])
        let access = try #require(body["access_token"] as? String)
        let refresh = try #require(body["refresh_token"] as? String)
        #expect(OAuthServer.validToken(access, prefix: "ekb_oat_v1_") && access.utf8.count == 75)
        #expect(OAuthServer.validToken(refresh, prefix: "ekb_ort_v1_"))
        #expect(h.server.accessPrefix == "ekb_oat_v1_" && h.server.refreshPrefix == "ekb_ort_v1_")
        #expect(body["token_type"] as? String == "Bearer" && body["expires_in"] as? Int == 3600)
        #expect(h.changedClients == [clientA])
        let views = h.server.connections(clientID: clientA)
        try #require(views.count == 1)
        #expect(views[0].appName == "Claude" && views[0].createdAt == h.clock)
        #expect(views[0].lastUsedAt == nil && h.server.connections(clientID: clientB).isEmpty)

        // Audience: only this MCP URL (scheme and host case-insensitive).
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        let upper = "HTTPS://My-Mac.tail1234.ts.net" + prefix + "/mcp"
        #expect(h.server.authenticate(accessToken: access, resource: upper) == clientA)
        #expect(h.server.authenticate(accessToken: access, resource: issuer) == nil)
        #expect(h.server.authenticate(accessToken: access, resource: "https://other.example/mcp") == nil)
        #expect(h.server.authenticate(accessToken: access, resource: origin + "/r/AbCdEfGhIjKlMnOpQrStUw/mcp") == nil)
        #expect(h.server.authenticate(accessToken: refresh, resource: resource) == nil)
        #expect(h.server.authenticate(accessToken: access.uppercased(), resource: resource) == nil)
        #expect(h.server.authenticate(accessToken: "", resource: resource) == nil)
        #expect(h.server.connections(clientID: clientA).first?.lastUsedAt == h.clock)
        // Cloud access off: refused at once.
        h.allowed = [clientB]
        #expect(h.server.authenticate(accessToken: access, resource: resource) == nil)
        #expect(json(h.refresh(refresh))["error"] as? String == "invalid_grant")
        h.allowed = [clientA, clientB]
        // One hour.
        h.advance(3599)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        h.advance(1)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == nil)
    }

    @Test("grant types, request shape and client authentication at the token endpoint")
    func tokenRequests() throws {
        let h = try Harness.fresh()
        let (_, refresh) = try h.connect()
        for grant in ["client_credentials", "password", "implicit", "urn:ietf:params:oauth:grant-type:device_code"] {
            let refused = h.post(prefix + "/oauth/token", [("grant_type", grant), ("client_id", cimdURL)])
            #expect(refused.status == 400, "\(grant)")
            #expect(json(refused)["error"] as? String == "unsupported_grant_type", "\(grant)")
        }
        #expect(json(h.post(prefix + "/oauth/token", [("client_id", cimdURL)]))["error"] as? String == "invalid_request")
        #expect(json(h.post(prefix + "/oauth/token", [("grant_type", "refresh_token")]))["error"]
            as? String == "invalid_request", "client_id required")
        let secret = h.post(prefix + "/oauth/token", [("grant_type", "refresh_token"), ("client_id", cimdURL),
                                                      ("client_secret", "s"), ("refresh_token", refresh)])
        #expect(secret.status == 401 && json(secret)["error"] as? String == "invalid_client")
        let refreshForm = [("grant_type", "refresh_token"), ("refresh_token", refresh)]
        let basic = h.post(prefix + "/oauth/token", refreshForm, headers: [
            ("authorization", "Basic " + Data("\(cimdURL):pw".utf8).base64EncodedString())])
        #expect(basic.status == 401 && header(basic, "www-authenticate")?.hasPrefix("Basic") == true)
        #expect(header(basic, "www-authenticate") == "Basic realm=\"EK Bridge\"")
        let jsonBody = h.send(Self.request("POST", prefix + "/oauth/token",
                                           body: Data("{\"grant_type\":\"refresh_token\"}".utf8),
                                           headers: [("content-type", "application/json")]))
        #expect(jsonBody.status == 400)
        let duplicate = h.post(prefix + "/oauth/token", [("grant_type", "refresh_token"),
                                                         ("grant_type", "authorization_code")])
        #expect(duplicate.status == 400)
        let huge = h.post(prefix + "/oauth/token", [("grant_type", "refresh_token"),
                                                    ("x", String(repeating: "a", count: 17_000))])
        #expect(huge.status == 400)
        // An empty-password Basic header names a public client, which is fine.
        let publicBasic = h.post(prefix + "/oauth/token", refreshForm, headers: [
            ("authorization", "Basic " + Data("\(encode(cimdURL)):".utf8).base64EncodedString())])
        #expect(publicBasic.status == 200, "\(text(publicBasic))")
    }

    // MARK: Refresh

    @Test("refresh rotates; reusing a rotated token revokes the connection")
    func refreshRotation() throws {
        let h = try Harness.fresh()
        let (access, refresh) = try h.connect()
        h.changedClients = []
        h.advance(100)
        let rotated = h.refresh(refresh)
        try #require(rotated.status == 200, "\(text(rotated))")
        let body = json(rotated)
        let access2 = try #require(body["access_token"] as? String)
        let refresh2 = try #require(body["refresh_token"] as? String)
        #expect(access2 != access && refresh2 != refresh)
        #expect(h.server.authenticate(accessToken: access2, resource: resource) == clientA)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == nil, "replaced")
        // Wrong client_id and wrong resource don't rotate or revoke.
        #expect(json(h.refresh(refresh2, clientID: "https://other.example/c.json"))["error"]
            as? String == "invalid_grant")
        let wrongResource = h.post(prefix + "/oauth/token", [
            ("grant_type", "refresh_token"), ("refresh_token", refresh2), ("client_id", cimdURL),
            ("resource", "https://other.example/mcp")])
        #expect(json(wrongResource)["error"] as? String == "invalid_target")
        #expect(h.server.authenticate(accessToken: access2, resource: resource) == clientA)
        #expect(h.changedClients.isEmpty)
        let third = json(h.refresh(refresh2))
        let refresh3 = try #require(third["refresh_token"] as? String)
        let access3 = try #require(third["access_token"] as? String)
        // Reuse of a rotated token revokes the whole connection.
        let reuse = h.refresh(refresh)
        #expect(reuse.status == 400 && json(reuse)["error"] as? String == "invalid_grant")
        #expect(h.server.authenticate(accessToken: access3, resource: resource) == nil)
        #expect(json(h.refresh(refresh3))["error"] as? String == "invalid_grant")
        #expect(h.server.connections(clientID: clientA).isEmpty && h.changedClients == [clientA])
        #expect(json(h.refresh("ekb_ort_v1_" + String(repeating: "0", count: 64)))["error"]
            as? String == "invalid_grant")
    }

    /// A token response lost in the tunnel: the client retries with the refresh token it just used.
    @Test("a retry within 30 s of a lost token response works; a late one revokes")
    func refreshRetry() throws {
        let h = try Harness.fresh()
        let (_, refresh) = try h.connect()
        h.advance(100)
        _ = try #require(json(h.refresh(refresh))["refresh_token"] as? String)
        h.advance(10)
        let retried = h.refresh(refresh)
        try #require(retried.status == 200, "retry within the grace period: \(text(retried))")
        let body = json(retried)
        let refresh3 = try #require(body["refresh_token"] as? String)
        let retriedAccess = try #require(body["access_token"] as? String)
        #expect(h.server.authenticate(accessToken: retriedAccess, resource: resource) == clientA)
        // The undelivered token is retired; the retried pair works normally.
        let next = h.refresh(refresh3)
        #expect(next.status == 200, "\(text(next))")
        #expect(h.server.connections(clientID: clientA).count == 1)
        // A retry past the grace period counts as reuse.
        h.advance(31)
        #expect(h.refresh(refresh3).status == 400)
        #expect(h.server.connections(clientID: clientA).isEmpty, "late retry revokes")
    }

    @Test("a retry after the new tokens were used is reuse")
    func refreshRetryAfterUse() throws {
        let h = try Harness.fresh()
        let (_, refresh) = try h.connect()
        let rotated = json(h.refresh(refresh))
        let rotatedAccess = try #require(rotated["access_token"] as? String)
        #expect(h.server.authenticate(accessToken: rotatedAccess, resource: resource) == clientA)
        // The new tokens reached the client (it used them), so the old refresh token is a leaked copy.
        #expect(h.refresh(refresh).status == 400)
        #expect(h.server.connections(clientID: clientA).isEmpty)
    }

    /// After Reset Secret Path or a new address, old connections can't refresh and are removed.
    @Test("connections for an old MCP URL can't refresh and are removed")
    func staleResource() throws {
        let h = try Harness.fresh()
        let (_, refresh) = try h.connect()
        let (_, refreshB) = try h.connect()
        let newPrefix = "/r/ZyXwVuTsRqPoNmLkJiHgFe"
        let newContext = OAuthContext(publicOrigin: origin, secretPrefix: newPrefix)
        var reply: HTTPResponse?
        _ = h.server.handle(Self.request("POST", newPrefix + "/oauth/token",
                                         body: Data(encodeQuery([("grant_type", "refresh_token"),
                                                                 ("refresh_token", refresh),
                                                                 ("client_id", cimdURL)]).dropFirst().utf8),
                                         headers: [("content-type", "application/x-www-form-urlencoded")]),
                            context: newContext) { reply = $0 }
        #expect(reply?.status == 400 && h.server.connections(clientID: clientA).count == 1,
                "a refresh for the old URL fails and ends that connection")
        h.changedClients = []
        #expect(h.server.revokeConnections(notFor: resource) == 0)
        #expect(h.server.revokeConnections(notFor: newContext.resource) == 1)
        #expect(h.server.connections(clientID: clientA).isEmpty && h.changedClients == [clientA])
        #expect(h.refresh(refreshB).status == 400)
    }

    @Test("each refresh restarts the 30 days; expired connections go")
    func refreshExpiry() throws {
        let h = try Harness.fresh()
        let (_, refresh) = try h.connect()
        // Each use restarts the 30 days.
        h.advance(29 * 86_400)
        let refresh2 = try #require(json(h.refresh(refresh))["refresh_token"] as? String)
        h.advance(30 * 86_400 - 1)
        #expect(h.server.connections(clientID: clientA).count == 1)
        let refresh3 = try #require(json(h.refresh(refresh2))["refresh_token"] as? String)
        h.advance(30 * 86_400)
        #expect(h.server.connections(clientID: clientA).isEmpty, "expired connections aren't listed")
        #expect(json(h.refresh(refresh3))["error"] as? String == "invalid_grant")
    }

    // MARK: Revocation

    @Test("RFC 7009 revocation, app-side revoke and revokeAll")
    func revocation() throws {
        let h = try Harness.fresh()
        let (access, refresh) = try h.connect()
        let (access2, refresh2) = try h.connect()
        #expect(h.server.connections(clientID: clientA).count == 2)
        // Unknown and malformed tokens: still 200.
        let unknownToken = "ekb_oat_v1_" + String(repeating: "f", count: 64)
        let unknown = h.post(prefix + "/oauth/revoke", [("token", unknownToken)])
        #expect(unknown.status == 200 && unknown.body.isEmpty)
        #expect(h.post(prefix + "/oauth/revoke", [("token", "garbage")]).status == 200)
        #expect(h.post(prefix + "/oauth/revoke", []).status == 400)
        // Another app's client_id can't revoke it.
        let foreign = [("token", access), ("client_id", "https://other.example/c.json")]
        #expect(h.post(prefix + "/oauth/revoke", foreign).status == 200)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        // Revoking the access token ends the connection, refresh token included.
        #expect(h.post(prefix + "/oauth/revoke", [("token", access), ("token_type_hint", "access_token"),
                                                  ("client_id", cimdURL)]).status == 200)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == nil)
        #expect(json(h.refresh(refresh))["error"] as? String == "invalid_grant")
        #expect(h.server.authenticate(accessToken: access2, resource: resource) == clientA)
        // Revoking by refresh token.
        #expect(h.post(prefix + "/oauth/revoke", [("token", refresh2)]).status == 200)
        #expect(h.server.authenticate(accessToken: access2, resource: resource) == nil)
        // App-side revoke and revokeAll.
        let (access3, _) = try h.connect()
        let (access4, _) = try h.connect()
        let target = try #require(h.server.connections(clientID: clientA).first)
        h.changedClients = []
        h.server.revoke(connectionID: target.id)
        #expect(h.changedClients == [clientA] && h.server.connections(clientID: clientA).count == 1)
        #expect(h.server.authenticate(accessToken: access3, resource: resource) == nil)
        h.server.revokeAll(clientID: clientA)
        #expect(h.server.authenticate(accessToken: access4, resource: resource) == nil)
        #expect(h.server.connections(clientID: clientA).isEmpty)
        // revokeAll also drops a code not yet redeemed.
        h.openWindow()
        let code = try h.pairedCode()
        h.server.revokeAll(clientID: clientA)
        #expect(json(h.exchange(code))["error"] as? String == "invalid_grant")
    }

    // MARK: Pairing window

    @Test("requests last 5 minutes, the window 10, and never outlive it")
    func pairingWindowLifetimes() throws {
        let h = try Harness.fresh()
        h.openWindow()
        #expect(h.pairingChanges == 1)
        #expect(h.authorize().status == 200)
        let first = try #require(h.server.pendingPairings.first)
        // Requests expire after 5 minutes.
        h.advance(301)
        #expect(h.server.pendingPairings.isEmpty)
        let expired = json(h.get(prefix + "/oauth/authorize/status", [("request", first.id.uuidString)]))
        #expect(expired["status"] as? String == "expired")
        h.server.answerPairing(first.id, allow: true)
        #expect(h.server.pairingClientID == clientA, "answering an expired request does nothing")
        // A request's lifetime never outlives the window.
        h.advance(200)
        #expect(h.authorize().status == 200)
        #expect(h.server.pendingPairings.first?.expiresAt == h.server.pairingExpiresAt)
        // The window lasts 10 minutes.
        h.advance(98)
        #expect(h.server.pairingClientID == clientA)
        h.advance(1)
        #expect(h.server.pairingClientID == nil && h.server.pendingPairings.isEmpty)
        let changes = h.pairingChanges
        #expect(h.authorize().status == 403)
        #expect(h.pairingChanges > changes, "expiry is announced")
    }

    @Test("another window replaces the first and drops its requests; answers stay readable briefly")
    func pairingWindowReplaced() throws {
        let h = try Harness.fresh()
        // Opening another window replaces the first and drops its requests.
        h.openWindow(clientA)
        #expect(h.authorize().status == 200)
        let stale = try #require(h.server.pendingPairings.first)
        h.openWindow(clientB)
        #expect(h.server.pairingClientID == clientB && h.server.pendingPairings.isEmpty)
        h.server.answerPairing(stale.id, allow: true)
        #expect(h.server.pairingClientID == clientB)
        #expect(json(h.status(stale.id))["status"] as? String == "expired")
        #expect(h.authorize().status == 200 && h.server.pendingPairings.first?.clientID == clientB)
        h.server.answerPairing(try #require(h.server.pendingPairings.first).id, allow: true)
        let last = try #require(h.requested.last)
        let tokens = json(h.exchange(try h.codeFromStatus(last.id)))
        let accessB = try #require(tokens["access_token"] as? String)
        #expect(h.server.authenticate(accessToken: accessB, resource: resource) == clientB)
        // Answered requests stay readable briefly, then go.
        h.advance(61)
        let gone = h.get(prefix + "/oauth/authorize/status", [("request", last.id.uuidString)])
        #expect(json(gone)["status"] as? String == "expired")
    }

    // MARK: Pages

    @Test("names are escaped and sanitized; one nonce'd script; the CSP")
    func escaping() throws {
        let h = try Harness.fresh()
        let evil = "https://evil.example/client.json"
        let name = "<script>alert('x')</script>\"&\u{202E}gpj.exe\u{0007}"
        h.fetcher.documents[evil] = .success(ClientMetadata(
            clientID: evil, clientName: name, redirectURIs: ["https://evil.example/cb?a=1"], clientURI: nil))
        h.openWindow()
        let page = h.authorize(clientID: evil, redirect: "https://evil.example/cb?a=1")
        #expect(page.status == 200)
        let html = text(page)
        #expect(!html.contains("<script>alert") && !html.contains("\u{202E}"))
        #expect(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;&quot;&amp;gpj.exe"))
        let request = try #require(h.requested.first)
        #expect(request.appName == "<script>alert('x')</script>\"&gpj.exe")
        // Exactly one script element: ours, carrying the nonce the CSP names.
        #expect(html.components(separatedBy: "<script").count == 2)
        let csp = try #require(header(page, "content-security-policy"))
        let nonce = try #require(csp.components(separatedBy: "'nonce-").dropFirst().first?
            .components(separatedBy: "'").first)
        #expect(html.contains("<script nonce=\"\(nonce)\">"))
        #expect(html.contains("<style nonce=\"\(nonce)\">"))
        #expect(!csp.contains("unsafe-inline") && csp.contains("connect-src 'self'"))
        #expect(csp.contains("default-src 'none'") && csp.contains("frame-ancestors 'none'"))
        #expect(!html.contains("http://") && !html.contains("src=") && !html.contains("href="))
        // An existing query in the redirect URI is kept.
        h.server.answerPairing(request.id, allow: true)
        let redirect = json(h.status(request.id))
        #expect((redirect["redirect"] as? String)?.hasPrefix("https://evil.example/cb?a=1&code=") == true)
        // Long names are cut to 100 bytes.
        #expect(OAuthServer.displayName(String(repeating: "é", count: 80))?.utf8.count == 100)
        #expect(OAuthServer.displayName(" \u{200B}\n ") == nil)
        #expect(OAuthPages.escape("a<b>&\"'") == "a&lt;b&gt;&amp;&quot;&#39;")
    }

    // MARK: Registration

    func register(_ h: Harness, _ object: [String: Any]) throws -> HTTPResponse {
        h.send(Self.request("POST", prefix + "/oauth/register",
                            body: try JSONSerialization.data(withJSONObject: object),
                            headers: [("content-type", "application/json")]))
    }

    @Test("dynamic client registration: only in a window, public clients, checked metadata")
    func dcrRegistration() throws {
        let h = try Harness.fresh()
        let callback = "https://chatgpt.com/connector_platform_oauth_redirect"
        // Registration needs an open pairing window, like authorization.
        h.server.closePairing()
        let closed = try register(h, ["redirect_uris": [callback], "client_name": "Early"])
        #expect(closed.status == 403 && json(closed)["error"] as? String == "access_denied")
        h.openWindow()
        let created = try register(h, ["redirect_uris": [callback], "client_name": "ChatGPT",
                                       "token_endpoint_auth_method": "none",
                                       "grant_types": ["authorization_code", "refresh_token"]])
        #expect(created.status == 201, "\(text(created))")
        #expect(header(created, "cache-control") == "no-store")
        let body = json(created)
        let clientID = try #require(body["client_id"] as? String)
        #expect(clientID.hasPrefix("dcr_") && clientID.count == 36)
        #expect(body["client_id_issued_at"] as? Int == Int(h.clock.timeIntervalSince1970))
        #expect(body["redirect_uris"] as? [String] == [callback])
        #expect(body["client_name"] as? String == "ChatGPT")
        #expect(body["token_endpoint_auth_method"] as? String == "none")
        #expect(body["client_secret"] == nil)
        // Loopback http is fine (RFC 8252); other http, custom schemes and fragments aren't.
        let loopback = ["http://127.0.0.1:3000/cb", "http://localhost/cb"]
        #expect(try register(h, ["redirect_uris": loopback]).status == 201)
        for bad: Any in [["http://example.com/cb"], ["javascript:alert(1)"], ["https://a.example/cb#f"],
                         [String](), Array(repeating: callback, count: 6), "https://a.example/cb",
                         ["https://user:pw@a.example/cb"], ["myapp://cb"],
                         ["https://exämple.com/cb"]] as [Any] {
            let refused = try register(h, ["redirect_uris": bad])
            #expect(refused.status == 400 && json(refused)["error"] as? String == "invalid_redirect_uri", "\(bad)")
        }
        let long = try register(h, ["redirect_uris": [callback], "client_name": String(repeating: "x", count: 101)])
        #expect(json(long)["error"] as? String == "invalid_client_metadata")
        #expect(json(try register(h, ["redirect_uris": [callback], "client_name": "a\nb"]))["error"]
            as? String == "invalid_client_metadata")
        #expect(json(try register(h, ["redirect_uris": [callback],
                                      "token_endpoint_auth_method": "client_secret_basic"]))["error"]
            as? String == "invalid_client_metadata")
        #expect(h.send(Self.request("POST", prefix + "/oauth/register", body: Data("[]".utf8),
                                    headers: [("content-type", "application/json")])).status == 400)
        #expect(h.send(Self.request("POST", prefix + "/oauth/register", body: Data(count: 17_000),
                                    headers: [("content-type", "application/json")])).status == 400)
    }

    @Test("a registered client connects; at most 100, oldest unused pruned first")
    func dcrConnectAndPrune() throws {
        let h = try Harness.fresh()
        let callback = "https://chatgpt.com/connector_platform_oauth_redirect"
        h.openWindow()
        let created = try register(h, ["redirect_uris": [callback], "client_name": "ChatGPT"])
        let clientID = try #require(json(created)["client_id"] as? String)
        // Register, then authorize and connect with it.
        h.openWindow()
        let page = h.authorize(clientID: clientID, redirect: callback)
        #expect(page.status == 200 && h.requested.last?.appName == "ChatGPT")
        #expect(h.requested.last?.appURL == nil && h.fetcher.fetched.isEmpty)
        let wrongRedirect = h.authorize(clientID: clientID, redirect: redirectURI)
        #expect(wrongRedirect.status == 400 && header(wrongRedirect, "location") == nil)
        let (access, _) = try h.connect(clientID: clientID, redirect: callback)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)

        // At most 100: the oldest unused registration goes first; used ones stay.
        h.openWindow()
        for index in 0..<120 {
            h.advance(1)
            let spam = try register(h, ["redirect_uris": [callback], "client_name": "spam \(index)"])
            #expect(spam.status == 201)
        }
        h.openWindow()
        #expect(h.authorize(clientID: clientID, redirect: callback).status == 200, "used registration kept")
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: h.storeFile))
            as? [String: Any])
        let registrations = try #require(stored["registrations"] as? [[String: Any]])
        #expect(registrations.count == 100)
        #expect(registrations.contains { $0["clientID"] as? String == clientID })
        #expect(!registrations.contains { $0["clientName"] as? String == "spam 0" })
        #expect(registrations.contains { $0["clientName"] as? String == "spam 119" })
    }

    /// Gemini Enterprise: a client ID and secret set up in the app, bound to one agent.
    @Test("confidential clients: set up in the app, bound to one agent, secret checked")
    func confidential() throws {
        let h = try Harness.fresh()
        let gemini = "https://vertexaisearch.cloud.google.com/oauth-redirect"
        #expect(h.server.registerConfidentialClient(for: clientA, name: "Gemini", redirectURI: "myapp://cb") == nil)
        h.allowed.remove(clientB)
        #expect(h.server.registerConfidentialClient(for: clientB, name: "Gemini", redirectURI: gemini) == nil)
        h.allowed.insert(clientB)
        let first = try #require(h.server.registerConfidentialClient(for: clientA, name: "Gemini",
                                                                     redirectURI: gemini))
        let issued = try #require(h.server.registerConfidentialClient(for: clientA, name: "Gemini",
                                                                      redirectURI: gemini))
        #expect(issued.clientID.hasPrefix("cfg_") && issued.clientID.count == 36)
        #expect(issued.secret.hasPrefix(h.server.secretPrefix) && issued.clientID != first.clientID)
        #expect(h.server.secretPrefix == "ekb_ocs_v1_")
        let path = h.storeFile
        let stored = String(decoding: try Data(contentsOf: path), as: UTF8.self)
        #expect(!stored.contains(issued.secret) && stored.contains(sha256(issued.secret)))
        #expect(!stored.contains(first.clientID), "an unused earlier client is replaced")

        // Only within a window for the same agent.
        h.openWindow(clientB)
        let other = h.authorize(clientID: issued.clientID, redirect: gemini)
        #expect(other.status == 403 && h.requested.isEmpty)
        h.openWindow()
        #expect(h.authorize(clientID: first.clientID, redirect: gemini).status == 400)
        #expect(h.authorize(clientID: issued.clientID, redirect: redirectURI).status == 400)
        let code = try h.pairedCode(clientID: issued.clientID, redirect: gemini)
        #expect(h.requested.last?.appName == "Gemini" && h.requested.last?.appURL == nil)

        func token(_ form: [(String, String)], headers: [(String, String)] = []) -> HTTPResponse {
            h.post(prefix + "/oauth/token", form, headers: headers)
        }
        let exchange: [(String, String)] = [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", gemini),
            ("code_verifier", verifier),
        ]
        func basic(_ user: String, _ password: String) -> (String, String) {
            ("authorization", "Basic " + Data("\(encode(user)):\(encode(password))".utf8).base64EncodedString())
        }
        // The secret is required, must be right and is sent once. None of these burn the code.
        for (form, headers) in [
            (exchange + [("client_id", issued.clientID)], []),
            (exchange + [("client_id", issued.clientID), ("client_secret", issued.secret + "x")], []),
            (exchange, [basic(issued.clientID, "wrong")]),
            (exchange + [("client_secret", issued.secret)], [basic(issued.clientID, issued.secret)]),
        ] as [([(String, String)], [(String, String)])] {
            let refused = token(form, headers: headers)
            #expect(refused.status == 401 && json(refused)["error"] as? String == "invalid_client",
                    "\(text(refused))")
        }
        let granted = token(exchange, headers: [basic(issued.clientID, issued.secret)])
        try #require(granted.status == 200, "\(text(granted))")
        let body = json(granted)
        let access = try #require(body["access_token"] as? String)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        // client_secret_post works for refresh; a public client can't send a secret.
        let refreshed = token([("grant_type", "refresh_token"),
                               ("refresh_token", try #require(body["refresh_token"] as? String)),
                               ("client_id", issued.clientID), ("client_secret", issued.secret)])
        #expect(refreshed.status == 200, "\(text(refreshed))")
        let (_, publicRefresh) = try h.connect()
        let publicWithSecret = token([("grant_type", "refresh_token"), ("refresh_token", publicRefresh),
                                      ("client_id", cimdURL), ("client_secret", "anything")])
        #expect(publicWithSecret.status == 401)
        // A used client survives a new setup; revoking everything for the agent removes both.
        let replacement = try #require(h.server.registerConfidentialClient(for: clientA, name: "Gemini",
                                                                           redirectURI: gemini))
        #expect(String(decoding: try Data(contentsOf: path), as: UTF8.self).contains(issued.clientID))
        h.server.revokeAll(clientID: clientA)
        let after = String(decoding: try Data(contentsOf: path), as: UTF8.self)
        #expect(!after.contains(issued.clientID) && !after.contains(replacement.clientID))
        #expect(h.server.authenticate(accessToken: access, resource: resource) == nil)
        // The file still loads after a restart.
        h.restart()
        #expect(h.server.isAvailable)
    }

    // MARK: Storage

    @Test("0600 file in a 0700 folder, digests only, lastUsedAt at most once a minute, survives restarts")
    func persistence() throws {
        let h = try Harness.fresh()
        let (access, refresh) = try h.connect()
        let file = h.storeFile
        var info = stat()
        #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(lstat(h.directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!contents.contains(access) && !contents.contains(refresh))
        #expect(!contents.contains("ekb_oat_v1_") && !contents.contains("ekb_ort_v1_"))
        #expect(!contents.contains(String(access.dropFirst(11))))
        #expect(!contents.contains(String(refresh.dropFirst(11))))
        #expect(contents.contains(sha256(access)) && contents.contains(sha256(refresh)))
        // lastUsedAt reaches the disk at most once a minute.
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        let firstUse = h.clock
        h.advance(30)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        h.restart()
        #expect(h.server.connections(clientID: clientA).first?.lastUsedAt == firstUse)
        // Survives a restart: tokens, refresh and listing.
        #expect(h.server.isAvailable)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        h.advance(30)
        let rotated = json(h.refresh(refresh))
        h.restart()
        let rotatedAccess = try #require(rotated["access_token"] as? String)
        #expect(h.server.authenticate(accessToken: rotatedAccess, resource: resource) == clientA)
        #expect(json(h.refresh(refresh))["error"] as? String == "invalid_grant", "reuse after restart")
        h.restart()
        #expect(h.server.connections(clientID: clientA).isEmpty, "the revocation persisted")
    }

    @Test("an unsafe or unreadable store closes everything and is never overwritten")
    func unsafeStore() throws {
        let h = try Harness(subfolder: "unsafe")
        let directory = h.directory
        let file = h.storeFile
        h.fetcher.documents[cimdURL] = .success(ClientMetadata(
            clientID: cimdURL, clientName: "Claude", redirectURIs: [redirectURI], clientURI: nil))
        let (access, refresh) = try h.connect()
        let good = try Data(contentsOf: file)
        func expectClosed(_ why: String, sourceLocation: SourceLocation = #_sourceLocation) {
            h.restart()
            #expect(!h.server.isAvailable, "\(why)", sourceLocation: sourceLocation)
            #expect(h.server.authenticate(accessToken: access, resource: resource) == nil, "\(why)",
                    sourceLocation: sourceLocation)
            #expect(h.server.connections(clientID: clientA).isEmpty, "\(why)", sourceLocation: sourceLocation)
            #expect(h.refresh(refresh).status == 503, "\(why)", sourceLocation: sourceLocation)
            h.openWindow()
            #expect(h.authorize().status == 503, "\(why)", sourceLocation: sourceLocation)
            #expect(h.post(prefix + "/oauth/revoke", [("token", access)]).status == 200, "\(why)",
                    sourceLocation: sourceLocation)
            // Discovery still answers; nothing is written.
            #expect(h.get("/.well-known/oauth-authorization-server" + prefix).status == 200, "\(why)",
                    sourceLocation: sourceLocation)
        }
        chmod(file.path, 0o644)
        expectClosed("group-readable file")
        #expect(try Data(contentsOf: file) == good, "an unsafe file is never overwritten")
        chmod(file.path, 0o600)
        h.restart()
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)

        try Data("{\"version\":1,\"connections\":[{}],\"registrations\":[]}".utf8).write(to: file)
        chmod(file.path, 0o600)
        expectClosed("invalid contents")
        try Data("{\"version\":2,\"connections\":[],\"registrations\":[]}".utf8).write(to: file)
        chmod(file.path, 0o600)
        expectClosed("unknown version")
        try FileManager.default.removeItem(at: file)
        let elsewhere = directory.appendingPathComponent("elsewhere.json")
        try good.write(to: elsewhere)
        chmod(elsewhere.path, 0o600)
        #expect(symlink(elsewhere.path, file.path) == 0)
        expectClosed("symlink")
        unlink(file.path)
        try Data(count: 2_000_001).write(to: file)
        chmod(file.path, 0o600)
        expectClosed("oversize")
        try good.write(to: file)
        chmod(file.path, 0o600)
        chmod(directory.path, 0o755)
        expectClosed("shared directory")
        chmod(directory.path, 0o700)
        h.restart()
        #expect(h.server.isAvailable)
        #expect(h.server.authenticate(accessToken: access, resource: resource) == clientA)
    }

    // MARK: Helpers

    func checkPageHeaders(_ page: HTTPResponse, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(header(page, "content-type") == "text/html; charset=utf-8", sourceLocation: sourceLocation)
        #expect(header(page, "x-frame-options") == "DENY", sourceLocation: sourceLocation)
        #expect(header(page, "referrer-policy") == "no-referrer", sourceLocation: sourceLocation)
        #expect(header(page, "cache-control") == "no-store", sourceLocation: sourceLocation)
        #expect(header(page, "content-security-policy")?.contains("connect-src 'self'") == true,
                sourceLocation: sourceLocation)
        #expect(!page.headers.contains { $0.name.lowercased().hasPrefix("access-control-") },
                sourceLocation: sourceLocation)
        // Serializable as-is: every header survives the response writer.
        let wire = String(decoding: page.serialized(close: false), as: UTF8.self)
        #expect(wire.contains("Content-Security-Policy: ") && wire.contains("X-Frame-Options: DENY"),
                sourceLocation: sourceLocation)
    }

    static func request(_ method: String, _ target: String, body: Data = Data(),
                        headers: [(String, String)] = []) -> HTTPRequest {
        HTTPRequest(method: method, target: target, path: String(target.prefix { $0 != "?" }),
                    version: "HTTP/1.1", headers: [("host", "my-mac.tail1234.ts.net")] + headers.map {
                        (name: $0.0.lowercased(), value: $0.1) }, body: body)
    }
}

// MARK: - Shared helpers

func header(_ response: HTTPResponse, _ name: String) -> String? {
    response.headers.first { $0.name.lowercased() == name.lowercased() }?.value
}

func text(_ response: HTTPResponse) -> String { String(decoding: response.body, as: UTF8.self) }

func json(_ response: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
}

private func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
}

private func encodeQuery(_ pairs: [(String, String)]) -> String {
    pairs.isEmpty ? "" : "?" + pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
}

private func queryItems(_ url: String) -> [String: String] {
    var items = [String: String]()
    for item in URLComponents(string: url)?.queryItems ?? [] { items[item.name] = item.value }
    return items
}

private func s256(_ verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
