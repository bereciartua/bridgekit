import Foundation

// Several apps on one Mac can share Tailscale Funnel, each on its own public
// port. These types say which ports are already served and which one Remote
// Access uses, so no app offers a command that replaces another app's entry.

/// What Tailscale serves on this Mac's public ports (`tailscale funnel status --json`), and the
/// public port Remote Access uses.
public struct FunnelPorts: Equatable, Sendable {
    /// The public ports Funnel can use, in the order the apps take them: whichever app is set up
    /// first gets the address without a port.
    public static let publicPorts = [443, 8443, 10000]

    /// One served public port.
    public struct Entry: Equatable, Sendable {
        public let publicPort: Int
        /// The host name it's served under, when Tailscale reports one (Web entries).
        public let host: String?
        /// The local ports it forwards to, lowest first. Empty for files, text and targets on another machine.
        public let targets: [Int]
        /// Public through Funnel; otherwise reachable from the tailnet only.
        public let funnel: Bool

        public init(publicPort: Int, host: String?, targets: [Int], funnel: Bool) {
            self.publicPort = publicPort
            self.host = host
            self.targets = targets
            self.funnel = funnel
        }

        /// `https://<host>[:<port>]`, when the host is known.
        public var address: String? { host.map { ToolJSON.origin(host: $0, port: publicPort) } }
    }

    /// Every served public port, Web and TCP, one entry each, lowest first.
    public let entries: [Entry]
    /// The Remote Access port.
    public let port: Int

    public init(entries: [Entry], port: Int) {
        self.entries = entries.sorted { $0.publicPort < $1.publicPort }
        self.port = port
    }

    public func entry(on publicPort: Int) -> Entry? { entries.first { $0.publicPort == publicPort } }

    /// Entries that forward to the Remote Access port, 443 first, so the usual address wins.
    private var own: [Entry] {
        entries.filter { $0.targets.contains(port) }
            .sorted { ($0.publicPort == 443 ? 0 : 1, $0.publicPort) < ($1.publicPort == 443 ? 0 : 1, $1.publicPort) }
    }

    /// The Funnel entry that forwards to the Remote Access port: it already runs there.
    public var running: Entry? { own.first { $0.funnel } }

    /// The public port to use:
    /// - where Funnel already forwards to the Remote Access port;
    /// - else where Serve does (turning Funnel on there is the fix);
    /// - else the first free one.
    /// A port is free only when nothing at all is served on it: `tailscale funnel --https=<p>`
    /// replaces the handler there and makes the whole port public. Nil when all three are taken.
    public var publicPort: Int? {
        if let entry = running ?? own.first(where: { Self.publicPorts.contains($0.publicPort) }) {
            return entry.publicPort
        }
        return Self.publicPorts.first { entry(on: $0) == nil }
    }

    /// What's served on the public ports Remote Access passed over: those before `publicPort`, or
    /// all three when none is free. Each forwards somewhere else. Empty when it uses the first
    /// port, or already runs.
    public var inTheWay: [Entry] {
        guard running == nil else { return [] }
        let skipped = publicPort.map { chosen in Self.publicPorts.prefix { $0 != chosen } } ?? Self.publicPorts[...]
        return skipped.compactMap { entry(on: $0) }
    }

    /// From `tailscale funnel status --json`; nil when it isn't JSON.
    public static func parse(funnel: Data?, port: Int) -> FunnelPorts? {
        guard let config = ToolJSON.object(funnel) else { return nil }
        let web = config["Web"] as? [String: Any] ?? [:]
        let tcp = config["TCP"] as? [String: Any] ?? [:]
        let allowFunnel = config["AllowFunnel"] as? [String: Any] ?? [:]
        let funnelPorts = Set(allowFunnel.compactMap { key, value -> Int? in
            guard value as? Bool == true else { return nil }
            return key.lastIndex(of: ":").flatMap { Int(key[key.index(after: $0)...]) } ?? Int(key)
        })
        var byPort = [Int: (host: String?, targets: Set<Int>)]()
        for (key, value) in web {
            guard let colon = key.lastIndex(of: ":"), let publicPort = Int(key[key.index(after: colon)...]) else { continue }
            let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            let targets = handlers.values.compactMap { ($0 as? [String: Any])?["Proxy"] as? String }
                .compactMap(ToolJSON.localPort)
            byPort[publicPort, default: (nil, [])].targets.formUnion(targets)
            byPort[publicPort]?.host = String(key[..<colon])
        }
        // TCP lists every served port: the HTTPS ones behind Web entries, and raw TCP forwarders.
        for (key, value) in tcp {
            guard let publicPort = Int(key) else { continue }
            let forward = ((value as? [String: Any])?["TCPForward"] as? String).flatMap(ToolJSON.localPort)
            byPort[publicPort, default: (nil, [])].targets.formUnion(forward.map { [$0] } ?? [])
        }
        let entries = byPort.map { publicPort, value in
            Entry(publicPort: publicPort, host: value.host, targets: value.targets.sorted(),
                  funnel: funnelPorts.contains(publicPort))
        }
        return FunnelPorts(entries: entries, port: port)
    }
}

/// The Tailscale Funnel commands for a public port, the same text in every app. 443 keeps the
/// short form.
public enum TailscaleFunnelCommand {
    public static func start(port: Int, publicPort: Int = 443) -> String {
        publicPort == 443 ? "tailscale funnel --bg \(port)" : "tailscale funnel --bg --https=\(publicPort) \(port)"
    }

    /// Turns off only the entry on `publicPort`, never another app's.
    public static func off(port: Int, publicPort: Int = 443) -> String {
        publicPort == 443 ? "tailscale funnel --bg \(port) off" : "tailscale funnel --https=\(publicPort) off"
    }

    /// The public port in an address: `https://host:8443` → 8443; 443 without a port.
    public static func publicPort(fromAddress address: String?) -> Int {
        address.flatMap(URL.init(string:))?.port ?? 443
    }
}

/// One tunnel check's answer.
public struct TunnelCheckResult: Equatable, Sendable {
    public let health: TunnelHealth
    /// Tailscale Funnel only: what's served on this Mac's public ports. Nil for the other
    /// tunnels, and when the check couldn't read it.
    public let funnel: FunnelPorts?

    public init(health: TunnelHealth, funnel: FunnelPorts? = nil) {
        self.health = health
        self.funnel = funnel
    }
}
