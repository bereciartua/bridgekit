import Foundation

// Several apps on one Mac can share Tailscale Funnel's port 443, the only one claude.ai and
// ChatGPT connect to: each adds only its own paths (`RemoteConfiguration.publicPaths`), and
// Tailscale sends every other path wherever it went before. These types read what's served and
// say where Remote Access runs or should run, so no app offers a command that replaces another
// app's entry or makes it public.

/// What Tailscale serves on this Mac's public ports (`tailscale funnel status --json`), seen from
/// one app: its Remote Access port and public paths.
public struct FunnelPorts: Equatable, Sendable {
    /// The public ports Funnel can use, in the order the apps take them.
    public static let publicPorts = [443, 8443, 10000]
    /// The one port claude.ai and ChatGPT connect to.
    public static let cloudAgentPort = 443

    /// One path entry on a public port: `tailscale funnel --set-path <path> <target>`.
    public struct Handler: Equatable, Sendable {
        /// `/`, or a path such as `/r/<secret>`.
        public let path: String
        /// The local port it forwards to; nil for files, text and targets on another machine.
        public let port: Int?
        /// The target's own path, such as `/r/<secret>`, or empty.
        public let targetPath: String

        public init(path: String, port: Int?, targetPath: String = "") {
            self.path = path
            self.port = port
            self.targetPath = targetPath
        }
    }

    /// One served public port.
    public struct Entry: Equatable, Sendable {
        public let publicPort: Int
        /// The host name it's served under, when Tailscale reports one (Web entries).
        public let host: String?
        /// Its path entries, by path.
        public let handlers: [Handler]
        /// Public through Funnel (for the whole port); otherwise reachable from the tailnet only.
        public let funnel: Bool
        /// A raw TCP forwarder's local port: it takes the whole port.
        public let tcpForward: Int?

        public init(publicPort: Int, host: String?, handlers: [Handler], funnel: Bool, tcpForward: Int? = nil) {
            self.publicPort = publicPort
            self.host = host
            self.handlers = handlers.sorted { $0.path < $1.path }
            self.funnel = funnel
            self.tcpForward = tcpForward
        }

        /// `https://<host>[:<port>]`, when the host is known.
        public var address: String? { host.map { ToolJSON.origin(host: $0, port: publicPort) } }

        /// The local ports it forwards to, lowest first.
        public var targets: [Int] {
            Array(Set(handlers.compactMap(\.port) + (tcpForward.map { [$0] } ?? []))).sorted()
        }

        public func handler(at path: String) -> Handler? { handlers.first { $0.path == path } }

        /// The whole port goes to `port`: a `/` entry, as setups before path sharing have.
        func forwardsWholePort(to port: Int) -> Bool { handler(at: "/")?.port == port }

        /// `path` goes to the same path on `port`.
        func forwards(_ path: String, to port: Int) -> Bool {
            guard let handler = handler(at: path) else { return false }
            return handler.port == port && handler.targetPath == path
        }
    }

    /// Every served public port, Web and TCP, one entry each, lowest first.
    public let entries: [Entry]
    /// The Remote Access port.
    public let port: Int
    /// Its public paths (`RemoteConfiguration.publicPaths`).
    public let paths: [String]

    public init(entries: [Entry], port: Int, paths: [String]) {
        self.entries = entries.sorted { $0.publicPort < $1.publicPort }
        self.port = port
        self.paths = paths
    }

    public func entry(on publicPort: Int) -> Entry? { entries.first { $0.publicPort == publicPort } }

    /// 443 first, so the address without a port wins.
    private var ordered: [Entry] {
        entries.sorted { ($0.publicPort == 443 ? 0 : 1, $0.publicPort) < ($1.publicPort == 443 ? 0 : 1, $1.publicPort) }
    }

    /// The app's paths an entry already forwards to it.
    public func ownPaths(_ entry: Entry) -> [String] { paths.filter { entry.forwards($0, to: port) } }

    /// Everything Remote Access answers goes to it: the whole port, or all of its paths.
    private func complete(_ entry: Entry) -> Bool {
        entry.forwardsWholePort(to: port) || (!paths.isEmpty && ownPaths(entry).count == paths.count)
    }

    private func forwardsAny(_ entry: Entry) -> Bool { entry.forwardsWholePort(to: port) || !ownPaths(entry).isEmpty }

    /// The Funnel entry that forwards everything Remote Access answers: it runs there.
    public var running: Entry? { ordered.first { $0.funnel && complete($0) } }

    /// A Funnel entry with some of the app's paths but not all, and the missing ones: sign-in or
    /// MCP fails until they're added.
    public var incomplete: (entry: Entry, missing: [String])? {
        guard running == nil, let entry = ordered.first(where: { $0.funnel && forwardsAny($0) }) else { return nil }
        let own = ownPaths(entry)
        return (entry, paths.filter { !own.contains($0) })
    }

    /// Adding the app's paths here leaves every other app as it is: nothing is served yet, or the
    /// port is already public through Funnel and isn't a raw TCP forwarder. Funnel is on or off for
    /// a whole port, so adding a Funnel path to a tailnet-only port would make its entries public.
    public func sharable(_ publicPort: Int) -> Bool {
        guard let entry = entry(on: publicPort) else { return true }
        return entry.funnel && entry.tcpForward == nil
    }

    /// The public port to use:
    /// - where it runs, or is incomplete;
    /// - else where Serve already forwards to it (turning Funnel on there is the fix);
    /// - else the first sharable one, 443 first.
    /// Nil when none is sharable.
    public var publicPort: Int? {
        if let entry = running ?? incomplete?.entry { return entry.publicPort }
        if let entry = ordered.first(where: { Self.publicPorts.contains($0.publicPort) && forwardsAny($0) }) {
            return entry.publicPort
        }
        return Self.publicPorts.first(where: sharable)
    }

    /// claude.ai and ChatGPT only connect to 443.
    public var reachesCloudAgents: Bool { publicPort == Self.cloudAgentPort }

    /// What's on the public ports Remote Access passed over: those before `publicPort`, or all
    /// three when none is sharable. Empty when it runs or uses 443.
    public var inTheWay: [Entry] {
        guard running == nil, incomplete == nil else { return [] }
        let skipped = publicPort.map { chosen in Self.publicPorts.prefix { $0 != chosen } } ?? Self.publicPorts[...]
        return skipped.compactMap { entry(on: $0) }
    }

    /// The paths still to add on `publicPort`: all of them, the missing ones when incomplete, or
    /// none when it runs.
    public var pathsToAdd: [String] {
        if running != nil { return [] }
        return incomplete?.missing ?? paths
    }

    /// From `tailscale funnel status --json`; nil when it isn't JSON.
    public static func parse(funnel: Data?, port: Int, paths: [String]) -> FunnelPorts? {
        guard let config = ToolJSON.object(funnel) else { return nil }
        let web = config["Web"] as? [String: Any] ?? [:]
        let tcp = config["TCP"] as? [String: Any] ?? [:]
        let allowFunnel = config["AllowFunnel"] as? [String: Any] ?? [:]
        let funnelPorts = Set(allowFunnel.compactMap { key, value -> Int? in
            guard value as? Bool == true else { return nil }
            return key.lastIndex(of: ":").flatMap { Int(key[key.index(after: $0)...]) } ?? Int(key)
        })
        var byPort = [Int: (host: String?, handlers: [Handler], tcpForward: Int?)]()
        for (key, value) in web {
            guard let colon = key.lastIndex(of: ":"), let publicPort = Int(key[key.index(after: colon)...]) else { continue }
            let handlers = ((value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]).map { path, handler in
                let target = ((handler as? [String: Any])?["Proxy"] as? String).flatMap(ToolJSON.target)
                return Handler(path: path, port: target?.port, targetPath: target?.path ?? "")
            }
            byPort[publicPort, default: (nil, [], nil)].handlers += handlers
            byPort[publicPort]?.host = String(key[..<colon])
        }
        // TCP lists every served port: the HTTPS ones behind Web entries, and raw TCP forwarders.
        for (key, value) in tcp {
            guard let publicPort = Int(key) else { continue }
            let forward = ((value as? [String: Any])?["TCPForward"] as? String).flatMap(ToolJSON.localPort)
            byPort[publicPort, default: (nil, [], nil)].tcpForward = forward
        }
        let entries = byPort.map { publicPort, value in
            Entry(publicPort: publicPort, host: value.host, handlers: value.handlers,
                  funnel: funnelPorts.contains(publicPort), tcpForward: value.tcpForward)
        }
        return FunnelPorts(entries: entries, port: port, paths: paths)
    }
}

/// The Tailscale Funnel commands, the same text in every app. Each names its port and path: a
/// bare `tailscale funnel --https=<p> off` turns off the whole port, every app on it included.
public enum TailscaleFunnelCommand {
    /// One command per path: each forwards the path to the same path on `port`, and leaves every
    /// other path on `publicPort` as it is.
    public static func start(port: Int, publicPort: Int = 443, paths: [String]) -> [String] {
        paths.map { "tailscale funnel --bg --https=\(publicPort) --set-path \($0) http://127.0.0.1:\(port)\($0)" }
    }

    /// Removes only these paths.
    public static func off(publicPort: Int = 443, paths: [String]) -> [String] {
        paths.map { "tailscale funnel --https=\(publicPort) --set-path \($0) off" }
    }

    /// What turns off this app's Funnel setup: its paths, or the `/` entry of a setup from before
    /// path sharing. The port is where the check found it, else the address's.
    public static func off(_ ports: FunnelPorts?, address: String?, paths: [String]) -> [String] {
        let entry = ports?.running ?? ports?.incomplete?.entry
        let publicPort = entry?.publicPort ?? publicPort(fromAddress: address)
        if let entry, let ports, entry.forwardsWholePort(to: ports.port) {
            return off(publicPort: publicPort, paths: ["/"])
        }
        return off(publicPort: publicPort, paths: paths)
    }

    /// Reset Path… with Funnel: the old secret's paths off, then the new ones on. Nothing for a
    /// `/` entry, which forwards any path.
    public static func resetPath(_ ports: FunnelPorts?, address: String?, port: Int, oldPaths: [String],
                                 newPaths: [String]) -> [String] {
        let entry = ports?.running ?? ports?.incomplete?.entry
        if let entry, entry.forwardsWholePort(to: port) { return [] }
        let publicPort = entry?.publicPort ?? publicPort(fromAddress: address)
        return off(publicPort: publicPort, paths: oldPaths) + start(port: port, publicPort: publicPort, paths: newPaths)
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
