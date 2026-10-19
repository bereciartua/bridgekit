import Foundation

// Is the tunnel running on this Mac? Pure parsers for what each tunnel's own
// tool reports, as typed results; each app words them. The checks that
// collect the input (TunnelChecks.swift) are read-only and local, and the
// result is display only: it never changes what the server accepts.

/// What a tunnel's tool says about it, for the Remote Access port.
public enum TunnelHealth: Equatable, Sendable {
    public enum NotRunningReason: Equatable, Sendable {
        /// The tool runs, but the tunnel isn't connected (Tailscale turned off,
        /// cloudflared not connected to Cloudflare yet).
        case stopped
        /// Tailscale needs a login.
        case loggedOut
        /// The tailnet policy doesn't allow Funnel for this Mac.
        case funnelNotAllowed
        /// No tunnel at all: start it.
        case noTunnel
        /// Tailscale Funnel: none of the three public ports (`FunnelPorts.publicPorts`) can take
        /// Remote Access's paths without changing another app: each has a tailnet-only entry
        /// (Funnel would make it public) or a raw TCP forwarder.
        case noSharablePort
    }

    /// Forwards to the Remote Access port. `address` is its public https
    /// address when the tool reports it.
    case running(address: String?, port: Int)
    /// Runs, but forwards to another port.
    case wrongPort(port: Int, address: String?)
    /// Tailscale Funnel forwards some of Remote Access's paths but not all (`missing` of them):
    /// sign-in or MCP fails until they're added.
    case incomplete(address: String?, missing: Int)
    /// Tailscale Serve without Funnel: reachable from the tailnet only.
    case notPublic(address: String?)
    case notRunning(reason: NotRunningReason)
    case notInstalled
    /// Other tunnel, or the check failed or timed out: the reachability test
    /// is the only signal.
    case unknown

    public enum Tone: Equatable, Sendable { case ok, warn, neutral }

    public var tone: Tone {
        switch self {
        case .running: .ok
        case .wrongPort, .incomplete, .notPublic, .notRunning: .warn
        case .notInstalled, .unknown: .neutral
        }
    }

    /// While Remote Access is on, these mean cloud agents can't get through (D10).
    public var warns: Bool {
        switch self {
        case .wrongPort, .incomplete, .notPublic, .notRunning: true
        case .running, .notInstalled, .unknown: false
        }
    }

    /// The sidebar badge's Down and the menu's "tunnel down" (D10): Remote
    /// Access is on with an address, and the tunnel in use warns.
    public static func isDown(remoteActive: Bool, health: TunnelHealth?) -> Bool {
        remoteActive && health?.warns == true
    }

    /// The public address the tool reported, if any.
    public var address: String? {
        switch self {
        case .running(let address, _), .wrongPort(_, let address), .incomplete(let address, _),
             .notPublic(let address): address
        case .notRunning, .notInstalled, .unknown: nil
        }
    }

    /// Whether the start command helps: the tunnel isn't up, but nothing else is in the way.
    public var showsStartCommand: Bool {
        if case .notRunning(let reason) = self { return reason == .noTunnel || reason == .stopped }
        return false
    }

    /// For the page's VoiceOver label and the live-test state.
    public var code: String {
        switch self {
        case .running: "running"
        case .wrongPort: "wrongPort"
        case .incomplete: "incomplete"
        case .notPublic: "notPublic"
        case .notRunning(let reason): "notRunning.\(reason)"
        case .notInstalled: "notInstalled"
        case .unknown: "unknown"
        }
    }
}

/// The Tunnel row's name (D4): the tunnel that answered the last test, then
/// what the address looks like, then the stored choice, so it can't disagree
/// with the address. A test answered by an unrecognized tunnel ("Other")
/// says less than the address or the choice, so it's used last.
public enum TunnelLabel {
    public static func resolve(lastTested: TunnelProvider?, address: String?, stored: TunnelProvider) -> TunnelProvider {
        if let lastTested, lastTested != .other { return lastTested }
        if let detected = TunnelProvider.detect(address: address) { return detected }
        if lastTested == .other, stored != .other, address != nil {
            // A Cloudflare Tunnel or ngrok on your own domain answers with no
            // header of its own: keep the choice.
            return stored
        }
        return lastTested ?? stored
    }
}

/// Reads JSON a CLI printed, skipping anything before the first `{` (the
/// `tailscale` CLI prints a version-mismatch warning on some installs).
public enum ToolJSON {
    public static func object(_ data: Data?) -> [String: Any]? {
        guard let data, let start = data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data[start...])) as? [String: Any]
    }

    /// The port a forwarding target names: `http://127.0.0.1:47616`,
    /// `http://localhost:47616/`, `localhost:47616`, `127.0.0.1:47616` or `47616`.
    /// Nil for anything else, including targets on another machine.
    public static func localPort(_ target: String) -> Int? { self.target(target)?.port }

    /// The local port and path a forwarding target names: `http://127.0.0.1:47627/r/abc` is
    /// (47627, `/r/abc`); a trailing slash alone is no path. Nil for targets on another machine.
    public static func target(_ target: String) -> (port: Int, path: String)? {
        var text = target.trimmingCharacters(in: .whitespaces)
        for scheme in ["http://", "https://", "tcp://"] where text.lowercased().hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        var path = ""
        if let slash = text.firstIndex(of: "/") {
            path = String(text[slash...])
            text = String(text[..<slash])
        }
        while path.hasSuffix("/") { path.removeLast() }
        text = text.lowercased()
        if let port = Int(text) { return (1...65_535).contains(port) ? (port, path) : nil }
        guard let colon = text.lastIndex(of: ":"), ["127.0.0.1", "localhost", "[::1]"].contains(String(text[..<colon])),
              let port = Int(text[text.index(after: colon)...]), (1...65_535).contains(port) else { return nil }
        return (port, path)
    }

    /// `https://<host>`, with `:<port>` unless it's 443.
    public static func origin(host: String, port: Int) -> String {
        "https://" + host.lowercased() + (port == 443 ? "" : ":\(port)")
    }
}

/// `tailscale status --json` and `tailscale funnel status --json`.
public enum TailscaleStatus {
    /// The environment for the `tailscale` CLI. Tailscale.app's binary is both
    /// the app and the CLI, and acts as the CLI only when it sees a shell
    /// (`SHLVL`, `TERM`) or `TAILSCALE_BE_CLI`. An app opened from Finder, at
    /// login or by an update has neither, so without the variable it answers
    /// "The Tailscale GUI failed to start" instead of JSON. Homebrew's CLI
    /// ignores it.
    public static func cliEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment["TAILSCALE_BE_CLI"] = "1"
        return environment
    }

    /// `paths` are the app's public paths (`RemoteConfiguration.publicPaths`). `mistakenPorts` are
    /// local ports a Funnel entry forwards to only by mistake, such as the app's own local MCP
    /// port: those are `.wrongPort`. Any other entry belongs to another app on this Mac and isn't
    /// this tunnel at all (`FunnelPorts` steers around it).
    public static func parse(status: Data?, funnel: Data?, port: Int, paths: [String],
                             mistakenPorts: Set<Int> = []) -> TunnelHealth {
        guard let status = ToolJSON.object(status) else { return .unknown }
        switch status["BackendState"] as? String {
        case "Running": break
        case "NeedsLogin", "NoState", "NeedsMachineAuth": return .notRunning(reason: .loggedOut)
        case "Stopped": return .notRunning(reason: .stopped)
        default: return .unknown
        }
        let me = status["Self"] as? [String: Any]
        guard let ports = FunnelPorts.parse(funnel: funnel, port: port, paths: paths) else { return .unknown }
        if let entry = ports.running {
            return .running(address: entry.address, port: port)
        }
        let capMap = me?["CapMap"] as? [String: Any]
        let capabilities = me?["Capabilities"] as? [String] ?? []
        let funnelAllowed = capMap.map { $0.keys.contains("funnel") } ?? true || capabilities.contains("funnel")
        if !funnelAllowed { return .notRunning(reason: .funnelNotAllowed) }
        if let (entry, missing) = ports.incomplete {
            return .incomplete(address: entry.address, missing: missing.count)
        }
        if let entry = ports.entries.first(where: { !$0.funnel && $0.targets.contains(port) }) {
            return .notPublic(address: entry.address)
        }
        for entry in ports.entries where entry.funnel {
            if let mistaken = entry.targets.first(where: mistakenPorts.contains) {
                return .wrongPort(port: mistaken, address: entry.address)
            }
        }
        if ports.publicPort == nil { return .notRunning(reason: .noSharablePort) }
        return .notRunning(reason: .noTunnel)
    }

    /// The health and the public ports in one answer, for the check.
    public static func result(status: Data?, funnel: Data?, port: Int, paths: [String],
                              mistakenPorts: Set<Int> = []) -> TunnelCheckResult {
        let health = parse(status: status, funnel: funnel, port: port, paths: paths, mistakenPorts: mistakenPorts)
        switch health {
        case .unknown, .notInstalled: return TunnelCheckResult(health: health)
        default:
            return TunnelCheckResult(health: health, funnel: FunnelPorts.parse(funnel: funnel, port: port, paths: paths))
        }
    }
}

/// One cloudflared metrics server (`127.0.0.1:20241…20245`): `/ready`,
/// `/quicktunnel` and `/config`, as fetched.
public struct CloudflaredEndpoint: Equatable, Sendable {
    public var ready: Data?
    public var quickTunnel: Data?
    public var config: Data?

    public init(ready: Data? = nil, quickTunnel: Data? = nil, config: Data? = nil) {
        self.ready = ready
        self.quickTunnel = quickTunnel
        self.config = config
    }
}

/// cloudflared: named tunnels and quick tunnels.
public enum CloudflaredStatus {
    /// `quick` picks quick tunnels (`--url`, a trycloudflare.com address) or
    /// named ones. `processes` are the arguments of running cloudflared
    /// processes (the fallback when no metrics server answers);
    /// `configFile` is `~/.cloudflared/config.yml` (or `--config`'s file).
    public static func parse(quick: Bool, endpoints: [CloudflaredEndpoint], processes: [[String]], configFile: String?,
                      port: Int, installed: Bool) -> TunnelHealth {
        let fileRules = configFile.map(ingress(yaml:)) ?? []
        var notReady = false
        var elsewhere: (port: Int, address: String?)?
        for endpoint in endpoints {
            let hostname = (ToolJSON.object(endpoint.quickTunnel)?["hostname"] as? String)?.lowercased() ?? ""
            guard hostname.isEmpty != quick else { continue }
            let rules = endpoint.config.map(ingress(json:)) ?? (quick ? [] : fileRules)
            let ready = (ToolJSON.object(endpoint.ready)?["readyConnections"] as? Int ?? 0) > 0
            guard ready else { notReady = true; continue }
            func address(_ rule: (hostname: String, port: Int)?) -> String? {
                if quick { return hostname.isEmpty ? nil : "https://" + hostname }
                guard let name = rule?.hostname, !name.isEmpty else { return nil }
                return "https://" + name
            }
            if let rule = rules.first(where: { $0.port == port }) {
                return .running(address: address(rule), port: port)
            }
            if let rule = rules.first, elsewhere == nil { elsewhere = (rule.port, address(rule)) }
            if rules.isEmpty && quick { return .running(address: address(nil), port: port) }
        }
        if let elsewhere { return .wrongPort(port: elsewhere.port, address: elsewhere.address) }
        if notReady { return .notRunning(reason: .stopped) }
        // No metrics server answered: look at the processes.
        let matching = processes.filter { args in
            let isQuick = TunnelProcess.cloudflaredURLPort(args) != nil
            return isQuick == quick && (quick || args.contains("run"))
        }
        if !matching.isEmpty {
            if quick {
                let ports = matching.compactMap(TunnelProcess.cloudflaredURLPort)
                if ports.contains(port) { return .running(address: nil, port: port) }
                return .wrongPort(port: ports[0], address: nil)
            }
            if let rule = fileRules.first(where: { $0.port == port }) {
                return .running(address: rule.hostname.isEmpty ? nil : "https://" + rule.hostname, port: port)
            }
            return .unknown
        }
        return installed ? .notRunning(reason: .noTunnel) : .notInstalled
    }

    /// `/config`'s `{"config": {"ingress": [{"hostname", "service"}]}}`.
    public static func ingress(json data: Data) -> [(hostname: String, port: Int)] {
        let config = ToolJSON.object(data)?["config"] as? [String: Any]
        let rules = config?["ingress"] as? [[String: Any]] ?? []
        return rules.compactMap { rule in
            guard let service = rule["service"] as? String, let port = ToolJSON.localPort(service) else { return nil }
            return ((rule["hostname"] as? String ?? "").lowercased(), port)
        }
    }

    /// The `ingress` rules of a config.yml: `hostname:` / `service:` pairs,
    /// read line by line (not a YAML parser; quotes and comments are dropped).
    public static func ingress(yaml text: String) -> [(hostname: String, port: Int)] {
        var rules = [(hostname: String, port: Int)]()
        var inIngress = false
        var hostname = ""
        func value(_ line: Substring, after key: String) -> String {
            var text = line.drop { $0 == " " || $0 == "-" }.dropFirst(key.count)
            if let hash = text.firstIndex(of: "#") { text = text[..<hash] }
            return text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")[...]
            if !line.hasPrefix(" ") && !line.hasPrefix("-") && !line.isEmpty && !line.hasPrefix("#") {
                inIngress = line.hasPrefix("ingress:")
                continue
            }
            guard inIngress else { continue }
            let trimmed = line.drop { $0 == " " || $0 == "-" }
            if trimmed.hasPrefix("hostname:") {
                hostname = value(line, after: "hostname:").lowercased()
            } else if trimmed.hasPrefix("service:") {
                let service = value(line, after: "service:")
                if let port = ToolJSON.localPort(service) { rules.append((hostname, port)) }
                hostname = ""
            }
        }
        return rules
    }
}

/// ngrok's agent API: `GET /api/tunnels`.
public enum NgrokStatus {
    public static func parse(apiTunnels data: Data?, port: Int) -> TunnelHealth {
        guard let object = ToolJSON.object(data), let tunnels = object["tunnels"] as? [[String: Any]] else {
            return .unknown
        }
        let found: [(address: String?, port: Int)] = tunnels.compactMap { tunnel in
            guard let addr = (tunnel["config"] as? [String: Any])?["addr"] as? String,
                  let target = ToolJSON.localPort(addr) else { return nil }
            let url = tunnel["public_url"] as? String
            return (url.flatMap(RemoteOriginText.normalized), target)
        }
        if let match = found.first(where: { $0.port == port }) {
            return .running(address: match.address, port: port)
        }
        if let other = found.first { return .wrongPort(port: other.port, address: other.address) }
        return .notRunning(reason: .noTunnel)
    }
}

/// The fallback when a tool's local status endpoint is off: the arguments of
/// a running process (same user only).
public enum TunnelProcess {
    /// `cloudflared tunnel --url http://127.0.0.1:47616` (or `--url=…`).
    public static func cloudflaredURLPort(_ args: [String]) -> Int? {
        value(args, "--url").flatMap(ToolJSON.localPort)
    }

    /// `ngrok http 47616` (or `localhost:47616`, `http://localhost:47616`).
    public static func ngrokPort(_ args: [String]) -> Int? {
        guard let index = args.firstIndex(of: "http"), index + 1 < args.count else { return nil }
        return args[(index + 1)...].first { !$0.hasPrefix("-") }.flatMap(ToolJSON.localPort)
    }

    /// `--config` of a named cloudflared tunnel, if given.
    public static func cloudflaredConfig(_ args: [String]) -> String? { value(args, "--config") }

    private static func value(_ args: [String], _ flag: String) -> String? {
        for (index, arg) in args.enumerated() {
            if arg == flag, index + 1 < args.count { return args[index + 1] }
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        return nil
    }
}

/// `https://host[:port]` from a tool's public URL, like `RemoteConfiguration.normalizedOrigin`.
public enum RemoteOriginText {
    public static func normalized(_ text: String) -> String? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return "https://" + host.lowercased() + (url.port.map { ":\($0)" } ?? "")
    }
}

/// When the tunnel is checked in the background: every 3 s
/// while a guide waits for the tunnel to start, every 60 s while Remote
/// Access is on, never while it's off. Opening the page, waking the Mac and
/// running Test check right away as well.
public enum TunnelCheckSchedule {
    public static let waitingInterval: TimeInterval = 3
    public static let onInterval: TimeInterval = 60

    public static func interval(remoteOn: Bool, waitingForTunnel: Bool) -> TimeInterval? {
        guard remoteOn else { return nil }
        return waitingForTunnel ? waitingInterval : onInterval
    }

    /// A clock that went back counts as due.
    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval?) -> Bool {
        guard let interval else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }
}

/// Step 2 of a guide (first setup and Switch Tunnel…) while you start the
/// tunnel: what it shows, and when it moves on by itself (D8). The step
/// itself still comes from the app's guide.
public enum TunnelStartState: Equatable, Sendable {
    /// Remote Access is off: turn it on first.
    case turnOn
    /// Checking every 3 s: *Waiting for Tailscale Funnel…*
    case waiting
    /// Running and forwarding to the Remote Access port.
    case found(address: String?)
    /// Running but set up wrong, or Tailscale can't run Funnel yet: the fix.
    case problem(TunnelHealth)
    /// Other tunnel, not installed, or the check can't tell: I've Started It.
    case cantCheck(TunnelHealth?)

    public static func make(remoteOn: Bool, provider: TunnelProvider, health: TunnelHealth?) -> TunnelStartState {
        guard remoteOn else { return .turnOn }
        if provider == .other { return .cantCheck(nil) }
        switch health {
        case nil: return .waiting
        case .running(let address, _)?: return .found(address: address)
        case .notRunning(let reason)? where reason == .noTunnel || reason == .stopped: return .waiting
        case .notRunning?, .wrongPort?, .incomplete?, .notPublic?: return .problem(health!)
        case .notInstalled?, .unknown?: return .cantCheck(health)
        }
    }

    /// Moves on to step 3 by itself only once per entry into step 2 from
    /// step 1: after Back from step 3 it shows Continue instead.
    public func autoAdvances(advancedThisEntry: Bool) -> Bool {
        if case .found = self { return !advancedThisEntry }
        return false
    }

    /// I've Started It: only when the check can't tell.
    public var offersStarted: Bool {
        if case .cantCheck = self { return true }
        return false
    }

    /// Continue: found, after Back from step 3.
    public var offersContinue: Bool {
        if case .found = self { return true }
        return false
    }
}
