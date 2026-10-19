import Foundation

/// Switch Tunnel… and Address ▸ Edit…: one switch's session-only state. The
/// tunnel and address in use keep working, and nothing is saved, until
/// Switch. Memory only: Cancel, quitting or turning Remote Access off leaves
/// everything as it was.
public struct TunnelSwitch: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Switch Tunnel…: Choose · Start it · Paste and test · Switch.
        case switchTunnel
        /// Address ▸ Edit…: the same tunnel at a new address, Paste and test · Save.
        case editAddress
    }

    public enum Step: Int, CaseIterable, Equatable, Sendable {
        case choose = 1, start, test, confirm
    }

    public enum Test: Equatable, Sendable {
        case notTested
        case testing(address: String)
        case reachable(address: String, ms: Int, tunnel: TunnelProvider?)
        /// `reason` is the app's words for the failure.
        case notReachable(address: String, reason: String)
    }

    /// Where step 3's address came from, for its caption.
    public enum AddressSource: Equatable, Sendable { case none, runningTunnel, remembered, inUse }

    public let kind: Kind
    /// The tunnel and address in use when the switch began.
    public let fromTunnel: TunnelProvider
    public let fromOrigin: String
    public var picked: TunnelProvider?
    /// Step 2 is behind us (found, Continue or I've Started It).
    public var started = false
    /// Step 2 moved on by itself since it was entered from step 1.
    public var advancedThisEntry = false
    /// Step 3's text field.
    public var address = ""
    public var addressSource = AddressSource.none
    public var test = Test.notTested
    /// Step 4, the confirmation sheet.
    public var confirming = false

    public init(kind: Kind, fromTunnel: TunnelProvider, fromOrigin: String) {
        self.kind = kind
        self.fromTunnel = fromTunnel
        self.fromOrigin = fromOrigin
        if kind == .editAddress {
            picked = fromTunnel
            started = true
            address = fromOrigin
            addressSource = .inUse
        }
    }

    public var step: Step {
        if confirming { return .confirm }
        guard picked != nil else { return .choose }
        return started ? .test : .start
    }

    /// The steps the header shows.
    public var steps: [Step] { kind == .editAddress ? [.test, .confirm] : Step.allCases }

    /// The tunnel in use can't be picked: a new address for it is Edit… (§4.3).
    public func canChoose(_ provider: TunnelProvider) -> Bool { provider != fromTunnel }

    /// The test result for the address now in the field (nil once it's edited).
    public func result(for normalized: String?) -> Test {
        switch test {
        case .notTested: return .notTested
        case .testing(let address), .reachable(let address, _, _), .notReachable(let address, _):
            return address == normalized ? test : .notTested
        }
    }

    /// Switch… (Save…) once the address in the field passed the test, and
    /// something would change.
    public func canConfirm(normalized: String?) -> Bool {
        guard let normalized, case .reachable = result(for: normalized) else { return false }
        return normalized != fromOrigin || picked != fromTunnel
    }

    /// A different tunnel answered than the one picked: say so, and offer to
    /// continue as that one. An unrecognized tunnel ("Other") says nothing.
    /// Other tunnel means any tunnel, so a recognized one answering isn't news.
    public var otherTunnel: TunnelProvider? {
        guard case .reachable(_, _, let tunnel?) = test, tunnel != .other, tunnel != picked,
              picked != .other else { return nil }
        return tunnel
    }

    /// Step 3's address: the running tunnel's, then the one remembered for it.
    public static func prefill(found: String?, remembered: String?) -> (String, AddressSource) {
        if let found { return (found, .runningTunnel) }
        if let remembered { return (remembered, .remembered) }
        return ("", .none)
    }
}

/// Step 4: what switching changes, by name.
public struct TunnelSwitchSummary: Equatable, Sendable {
    public let tunnel: TunnelProvider
    /// The new MCP URL with the secret path hidden.
    public let mcpURL: String
    /// Agents with cloud access and a remote token: they need the new URL.
    public let updateURLIn: [String]
    /// Signed-in cloud apps (OAuth): bound to the old URL, so they're disconnected.
    public let disconnected: [String]
    /// The old tunnel and its off command, when it has one.
    public let stopTunnel: TunnelProvider?
    public let stopCommands: [String]

    public var noCloudAgents: Bool { updateURLIn.isEmpty && disconnected.isEmpty }

    /// `offCommands` are the app's commands that turn a tunnel off (only Funnel keeps
    /// running in the background), given the tunnel, the Remote Access port and the address being
    /// left (its port is Funnel's public port: `TailscaleFunnelCommand.publicPort(fromAddress:)`).
    public static func make(_ change: TunnelSwitch, newOrigin: String, port: Int, remoteTokenClients: [String],
                            oauthApps: [String],
                            offCommands: (TunnelProvider, Int, String) -> [String]) -> TunnelSwitchSummary {
        let tunnel = change.picked ?? change.fromTunnel
        // Same address through another tunnel: the URL stays, nothing needs updating.
        let urlChanges = newOrigin != change.fromOrigin
        let off = offCommands(change.fromTunnel, port, change.fromOrigin)
        let stopping = change.kind == .switchTunnel && tunnel != change.fromTunnel && !off.isEmpty
        return TunnelSwitchSummary(
            tunnel: tunnel,
            mcpURL: newOrigin + "/r/••••••/mcp",
            updateURLIn: urlChanges ? remoteTokenClients : [],
            disconnected: urlChanges ? oauthApps : [],
            stopTunnel: stopping ? change.fromTunnel : nil,
            stopCommands: stopping ? off : [])
    }
}

/// Each tunnel's last address: UserDefaults `RemoteTunnelAddresses` (by
/// default), `{tunnel: address}`.
public enum TunnelAddressMemory {
    public static let key = "RemoteTunnelAddresses"

    public static func load(_ defaults: UserDefaults, key: String = key) -> [TunnelProvider: String] {
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        var result = [TunnelProvider: String]()
        for (raw, origin) in stored {
            if let provider = TunnelProvider(rawValue: raw), origin.hasPrefix("https://"), origin.count <= 300 {
                result[provider] = origin
            }
        }
        return result
    }

    public static func save(_ addresses: [TunnelProvider: String], _ defaults: UserDefaults, key: String = key) {
        defaults.set(Dictionary(uniqueKeysWithValues: addresses.map { ($0.key.rawValue, $0.value) }), forKey: key)
    }

    /// The hostname step 2 pre-fills for Cloudflare Tunnel and ngrok.
    public static func hostname(_ origin: String?) -> String? {
        origin.flatMap(URL.init(string:))?.host
    }
}
