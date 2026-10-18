import BridgeKitCore
import Foundation

// The seam between BridgeKitRemote and an app. The kit runs the Remote Access
// listener, its OAuth authorization server, the client-metadata fetch and the
// tunnel checks; which agent a credential belongs to, and whether that agent
// may be used from the internet, stay in the app.

/// The words the remote tier says on the app's behalf: to agents (401s) and in
/// the browser (the sign-in pages and OAuth errors). Each app supplies its own
/// so people see its terms ("client", "agent").
public struct RemoteTexts: Sendable, Equatable {
    /// 401 on the remote MCP endpoint: an unknown, refused or local credential.
    public var unauthorized: String
    /// 403: an `Origin` header on the remote MCP endpoint.
    public var originRefused: String
    /// The "Pairing isn't open" page.
    public var pairingClosed: String
    /// Under the app's name on the code page: compare the code, then Allow on the Mac.
    public var pairingPrompt: String
    /// The label of the row naming the app's agent on the code page ("Client", "Agent").
    public var agentLabel: String
    /// `error_description` when the user chose Deny.
    public var declined: String
    /// A `redirect_uri` the app didn't register.
    public var redirectNotRegistered: String
    /// The metadata document couldn't be used; the reason and "Try connecting again." follow.
    public var metadataUnusable: String
    /// A confidential client set up for another agent.
    public var setUpForAnotherTitle: String
    public var setUpForAnother: String
    /// The page when the agent's cloud access was turned off during pairing.
    public var cloudAccessOffPage: String
    /// `error_description` for codes and refresh tokens of an agent without cloud access.
    public var cloudAccessOff: String
    /// The connection store is full.
    public var tooManyConnections: String
    /// Dynamic registration outside a pairing window.
    public var registrationClosed: String
    /// The page when the connection store can't be read.
    public var storeUnavailable: String

    public init(unauthorized: String, originRefused: String = "Requests from web pages aren't accepted.",
                pairingClosed: String, pairingPrompt: String, agentLabel: String, declined: String,
                redirectNotRegistered: String, metadataUnusable: String, setUpForAnotherTitle: String,
                setUpForAnother: String, cloudAccessOffPage: String, cloudAccessOff: String,
                tooManyConnections: String, registrationClosed: String, storeUnavailable: String) {
        self.unauthorized = unauthorized
        self.originRefused = originRefused
        self.pairingClosed = pairingClosed
        self.pairingPrompt = pairingPrompt
        self.agentLabel = agentLabel
        self.declined = declined
        self.redirectNotRegistered = redirectNotRegistered
        self.metadataUnusable = metadataUnusable
        self.setUpForAnotherTitle = setUpForAnotherTitle
        self.setUpForAnother = setUpForAnother
        self.cloudAccessOffPage = cloudAccessOffPage
        self.cloudAccessOff = cloudAccessOff
        self.tooManyConnections = tooManyConnections
        self.registrationClosed = registrationClosed
        self.storeUnavailable = storeUnavailable
    }

    /// Plain defaults built from the display name and what the app calls an agent
    /// ("client" is EK Bridge's wording).
    public static func standard(displayName app: String, agent: String = "client") -> RemoteTexts {
        let label = agent.prefix(1).uppercased() + agent.dropFirst()
        return RemoteTexts(
            unauthorized: "\(app) doesn't recognize this credential. Use the \(agent)'s remote token or connect "
                + "the app again from the \(agent)'s Cloud section.",
            pairingClosed: "In \(app) on your Mac, open the \(agent) you want to use and choose Connect a Cloud "
                + "App. Then start connecting again from the app.",
            pairingPrompt: "Check that \(app) on your Mac shows this code, then choose Allow there.",
            agentLabel: label,
            declined: "The connection was declined in \(app).",
            redirectNotRegistered: "The redirect_uri doesn’t exactly match one the app registered, so \(app) "
                + "won’t send you there.",
            metadataUnusable: "\(app) couldn’t use the app’s metadata document.",
            setUpForAnotherTitle: "This app was set up for another \(agent)",
            setUpForAnother: "Pairing is open for a different \(agent) in \(app). Open the \(agent) this app was "
                + "set up for and choose Connect a Cloud App.",
            cloudAccessOffPage: "This \(agent) no longer allows cloud access. Turn it on in \(app) and connect "
                + "again.",
            cloudAccessOff: "This \(agent) no longer allows cloud access.",
            tooManyConnections: "Too many connected apps. Revoke some in \(app) first.",
            registrationClosed: "Pairing isn't open. In \(app) on the Mac, open the \(agent) and choose Connect a "
                + "Cloud App.",
            storeUnavailable: "\(app) can’t read its list of connected apps, so it isn’t accepting new ones. "
                + "Check the app on your Mac.")
    }
}

/// Everything that differs between apps built on BridgeKitRemote.
public struct RemoteBridgeConfiguration: Sendable {
    /// Display name (pages, realms, the keep-awake reason) and version (the
    /// client-metadata fetch's `User-Agent`).
    public var identity: BridgeIdentity
    /// 47616 EK Bridge · 47627 Funes. Only the listener's default; the app
    /// saves the port the user picks.
    public var defaultPort: Int
    /// "ekb_mcpr_v1_" · "fns_mcpr_v1_": header-sending agents' remote tokens.
    public var remoteTokenPrefix: String
    /// OAuth access and refresh tokens, and the secrets of clients set up ahead.
    public var accessTokenPrefix: String
    public var refreshTokenPrefix: String
    public var clientSecretPrefix: String
    /// "calendar" · "memory".
    public var scope: String
    /// The `User-Agent` product of the client-metadata fetch ("EKBridge" · "FunesVault"):
    /// `<product>/<version>`, ASCII only.
    public var userAgentProduct: String
    /// Where `remote-connections.json` lives (0700).
    public var storeDirectory: URL
    public var texts: RemoteTexts

    public init(identity: BridgeIdentity, defaultPort: Int, remoteTokenPrefix: String, accessTokenPrefix: String,
                refreshTokenPrefix: String, clientSecretPrefix: String, scope: String, userAgentProduct: String,
                storeDirectory: URL, texts: RemoteTexts? = nil) {
        self.identity = identity
        self.defaultPort = defaultPort
        self.remoteTokenPrefix = remoteTokenPrefix
        self.accessTokenPrefix = accessTokenPrefix
        self.refreshTokenPrefix = refreshTokenPrefix
        self.clientSecretPrefix = clientSecretPrefix
        self.scope = scope
        self.userAgentProduct = userAgentProduct
        self.storeDirectory = storeDirectory
        self.texts = texts ?? .standard(displayName: identity.displayName)
    }

    /// `<product>/<version>`; the version is "0" unless it's plain ASCII
    /// letters, digits and dots (unbundled builds report "–").
    public var userAgent: String {
        let version = identity.version
        let plain = !version.isEmpty
            && version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }
        return userAgentProduct + "/" + (plain ? version : "0")
    }
}

/// App-owned storage, kit-owned crypto: which agent a remote credential
/// belongs to, and whether that agent may be used from the internet. Replaces
/// EK Bridge's direct `ClientRegistry` calls.
@MainActor
public protocol RemoteAuthenticator: AnyObject {
    /// A remote token, already checked for shape (the configuration's prefix and
    /// 64 lowercase hex digits). Only agents with cloud access on match; compare
    /// digests with `AgentKey.matches`/`firstMatch`.
    func authenticate(remoteToken: PresentedKey) async -> AuthenticationOutcome
    /// An agent an OAuth access token was issued to: authenticated only while it
    /// still has cloud access. The default asks `cloudAccessAllowed` and `agentName`.
    func authenticate(agentID: String) async -> AuthenticationOutcome
    /// Whether the agent may be used from Remote Access right now (cloud access
    /// on, not removed). OAuth asks before every pairing, code and refresh.
    func cloudAccessAllowed(agentID: String) -> Bool
    /// The agent's name, for the code page and `server/discover`; nil if unknown.
    func agentName(agentID: String) -> String?
    /// A remote credential was refused. The per-address lockout is the kit's;
    /// this is for the app's own records (an Activity row). Default: nothing.
    func recordFailedRemoteAuth()
}

extension RemoteAuthenticator {
    public func authenticate(agentID: String) async -> AuthenticationOutcome {
        guard cloudAccessAllowed(agentID: agentID) else { return .rejected }
        return .authenticated(AuthenticatedAgent(id: agentID, name: agentName(agentID: agentID)))
    }

    public func recordFailedRemoteAuth() {}
}
