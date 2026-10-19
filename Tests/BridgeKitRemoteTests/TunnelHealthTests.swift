import Foundation
import Testing
@testable import BridgeKitRemote

/// Plan 08 T01: what each tunnel's tool reports, parsed from fixtures (`fixtures/tunnel-health`;
/// Tailscale's captured on a real Mac, anonymized), the Tunnel row's name, what each state means
/// and the check schedule. The words for each state are the app's and are tested there.
@Suite("Tunnel health")
struct TunnelHealthTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.resourceURL?.appendingPathComponent("fixtures/tunnel-health/\(name)"))
        return try Data(contentsOf: url)
    }

    // MARK: Parsers

    @Test("Tailscale: status and funnel status")
    func tailscale() throws {
        let status = try Self.fixture("tailscale-status.json")
        let funnel = try Self.fixture("tailscale-funnel.json")
        let parse = { (status: Data?, funnel: Data?, port: Int) in
            TailscaleStatus.parse(status: status, funnel: funnel, port: port, mistakenPorts: [47615])
        }
        // The real config: Funnel on 443 → 47616, and another app's Serve entry on 8443.
        #expect(parse(status, funnel, 47616) == .running(address: "https://my-mac.tail1234.ts.net", port: 47616),
                "running")
        // Another app's port (Funes on the same Mac): 443 and 8443 belong to other apps, not to this
        // tunnel at the wrong port. Not started yet; FunnelPorts picks 10000.
        #expect(parse(status, funnel, 47627) == .notRunning(reason: .noTunnel), "other apps' entries aren't wrong port")
        #expect(parse(status, try Self.fixture("tailscale-funnel-warning.txt"), 47616)
            == .running(address: "https://my-mac.tail1234.ts.net", port: 47616), "version warning before the JSON")
        var warned = Data("Warning: client version \"1\" != tailscaled server version \"2\"\n".utf8)
        warned.append(status)
        #expect(parse(warned, funnel, 47616) == .running(address: "https://my-mac.tail1234.ts.net", port: 47616),
                "warning before the status JSON")
        #expect(parse(status, try Self.fixture("tailscale-funnel-serve-only.json"), 47616)
            == .notPublic(address: "https://my-mac.tail1234.ts.net"), "Serve without Funnel")
        #expect(parse(status, try Self.fixture("tailscale-funnel-wrong-port.json"), 47616)
            == .wrongPort(port: 47615, address: "https://my-mac.tail1234.ts.net"), "Funnel to the MCP port")
        #expect(TailscaleStatus.parse(status: status, funnel: try Self.fixture("tailscale-funnel-wrong-port.json"),
                                      port: 47616) == .notRunning(reason: .noTunnel),
                "a port the app doesn't name as a mistake is another app's")
        #expect(parse(status, try Self.fixture("tailscale-funnel-all-taken.json"), 47627)
            == .notRunning(reason: .allPortsTaken), "all three public ports taken")
        #expect(parse(status, try Self.fixture("tailscale-funnel-all-taken.json"), 47616)
            == .running(address: "https://my-mac.tail1234.ts.net", port: 47616), "running wins over all taken")
        #expect(parse(status, try Self.fixture("tailscale-funnel-10000.json"), 47627)
            == .running(address: "https://my-mac.tail1234.ts.net:10000", port: 47627), "running on 10000")
        #expect(parse(status, try Self.fixture("tailscale-funnel-8443.json"), 47616)
            == .running(address: "https://my-mac.tail1234.ts.net:8443", port: 47616), "8443, localhost and a slash")
        #expect(parse(status, try Self.fixture("tailscale-funnel-none.json"), 47616)
            == .notRunning(reason: .noTunnel), "no Funnel")
        #expect(parse(try Self.fixture("tailscale-status-logged-out.json"), Data("{}".utf8), 47616)
            == .notRunning(reason: .loggedOut), "logged out")
        #expect(parse(try Self.fixture("tailscale-status-stopped.json"), funnel, 47616)
            == .notRunning(reason: .stopped), "stopped")
        #expect(parse(try Self.fixture("tailscale-status-no-funnel.json"),
                      try Self.fixture("tailscale-funnel-serve-only.json"), 47616)
            == .notRunning(reason: .funnelNotAllowed), "Funnel not allowed in the policy")
        // A Funnel entry that runs wins over the policy check (CapMap can lag).
        #expect(parse(try Self.fixture("tailscale-status-no-funnel.json"), funnel, 47616)
            == .running(address: "https://my-mac.tail1234.ts.net", port: 47616), "running despite CapMap")
        #expect(parse(nil, funnel, 47616) == .unknown, "no status")
        #expect(parse(Data("not json".utf8), funnel, 47616) == .unknown, "garbage")
        #expect(parse(status, nil, 47616) == .unknown, "no funnel status")
        #expect(parse(Data(#"{"BackendState":"Starting"}"#.utf8), funnel, 47616) == .unknown, "an unknown state")
        // What Tailscale.app's binary prints when it doesn't run as the CLI (0.11.0's bug).
        #expect(parse(Data("The Tailscale GUI failed to start: The operation couldn’t be completed.\n".utf8),
                      nil, 47616) == .unknown, "the GUI answer")
    }

    @Test("Tailscale's CLI is asked for by name")
    func tailscaleCLIEnvironment() {
        // An app opened from Finder has no SHLVL or TERM: the CLI is asked for by name.
        let environment = TailscaleStatus.cliEnvironment(["HOME": "/Users/test", "PATH": "/usr/bin:/bin"])
        #expect(environment == ["HOME": "/Users/test", "PATH": "/usr/bin:/bin", "TAILSCALE_BE_CLI": "1"],
                "TAILSCALE_BE_CLI added, the rest kept")
    }

    @Test("cloudflared: metrics endpoints, processes and config.yml")
    func cloudflared() throws {
        let ready = try Self.fixture("cloudflared-ready.json")
        let quick = CloudflaredEndpoint(ready: ready, quickTunnel: try Self.fixture("cloudflared-quicktunnel.json"),
                                        config: try Self.fixture("cloudflared-config-quick.json"))
        let named = CloudflaredEndpoint(ready: ready,
                                        quickTunnel: try Self.fixture("cloudflared-quicktunnel-named.json"),
                                        config: nil)
        let yaml = String(decoding: try Self.fixture("cloudflared-config.yml"), as: UTF8.self)
        func parse(_ isQuick: Bool, _ endpoints: [CloudflaredEndpoint], processes: [[String]] = [],
                   config: String? = nil, port: Int = 47616, installed: Bool = true) -> TunnelHealth {
            CloudflaredStatus.parse(quick: isQuick, endpoints: endpoints, processes: processes, configFile: config,
                                    port: port, installed: installed)
        }
        #expect(parse(true, [quick]) == .running(address: "https://quiet-river-1234.trycloudflare.com", port: 47616),
                "quick tunnel")
        #expect(parse(true, [quick], port: 47626)
            == .wrongPort(port: 47616, address: "https://quiet-river-1234.trycloudflare.com"),
                "quick tunnel to another port")
        // Without /config (older cloudflared): the quick tunnel is taken as running.
        #expect(parse(true, [CloudflaredEndpoint(ready: ready, quickTunnel: quick.quickTunnel, config: nil)])
            == .running(address: "https://quiet-river-1234.trycloudflare.com", port: 47616), "no /config")
        #expect(parse(true, [CloudflaredEndpoint(ready: try Self.fixture("cloudflared-not-ready.json"),
                                                 quickTunnel: quick.quickTunnel, config: quick.config)])
            == .notRunning(reason: .stopped), "not connected yet")
        // A quick tunnel isn't a named one, and the other way round.
        #expect(parse(false, [quick]) == .notRunning(reason: .noTunnel), "quick isn't named")
        #expect(parse(true, [named], config: yaml) == .notRunning(reason: .noTunnel), "named isn't quick")
        #expect(parse(false, [named], config: yaml) == .running(address: "https://mcp.example.com", port: 47616),
                "named, from config.yml")
        #expect(parse(false, [CloudflaredEndpoint(ready: ready, quickTunnel: named.quickTunnel,
                                                  config: try Self.fixture("cloudflared-config-named.json"))])
            == .running(address: "https://mcp.example.com", port: 47616), "named, from /config")
        #expect(parse(false, [named], config: yaml, port: 47626)
            == .wrongPort(port: 8080, address: "https://wiki.example.com"), "named, another port")
        // Two metrics servers: the second one is ours.
        let other = CloudflaredEndpoint(
            ready: ready, quickTunnel: Data(#"{"hostname":"other-name-9.trycloudflare.com"}"#.utf8),
            config: Data(#"{"config":{"ingress":[{"service":"http://127.0.0.1:8080"}]}}"#.utf8))
        #expect(parse(true, [other, quick]) == .running(address: "https://quiet-river-1234.trycloudflare.com",
                                                        port: 47616), "the matching tunnel among several")
        // No metrics server: the processes.
        let quickArgs = ["cloudflared", "tunnel", "--url", "http://127.0.0.1:47616", "--http-host-header",
                         "127.0.0.1:47616"]
        #expect(parse(true, [], processes: [quickArgs]) == .running(address: nil, port: 47616), "quick tunnel process")
        #expect(parse(true, [], processes: [quickArgs], port: 47626) == .wrongPort(port: 47616, address: nil),
                "process, another port")
        #expect(parse(false, [], processes: [["cloudflared", "tunnel", "run", "ek-bridge"]], config: yaml)
            == .running(address: "https://mcp.example.com", port: 47616), "named process with config.yml")
        #expect(parse(false, [], processes: [["cloudflared", "tunnel", "run", "ek-bridge"]]) == .unknown,
                "named process without details")
        #expect(parse(true, []) == .notRunning(reason: .noTunnel), "nothing running")
        #expect(parse(true, [], installed: false) == .notInstalled, "not installed")
    }

    @Test("config.yml ingress rules, line by line")
    func cloudflaredIngress() throws {
        let yaml = String(decoding: try Self.fixture("cloudflared-config.yml"), as: UTF8.self)
        let rules = CloudflaredStatus.ingress(yaml: yaml)
        #expect(rules.map(\.hostname) == ["wiki.example.com", "mcp.example.com"] && rules.map(\.port) == [8080, 47616],
                "two ingress rules, quotes dropped, http_status skipped")
        #expect(CloudflaredStatus.ingress(
            yaml: "tunnel: x\ningress:\n\t- hostname: a.example.com # mine\n\t  service: localhost:47616\n")
            .map(\.port) == [47616], "tabs and comments")
        #expect(CloudflaredStatus.ingress(yaml: "ingress:\n  - service: http://192.168.1.2:47616\n").isEmpty,
                "another machine isn't this Mac")
    }

    @Test("ngrok's API and local forwarding targets")
    func ngrok() throws {
        let tunnels = try Self.fixture("ngrok-tunnels.json")
        #expect(NgrokStatus.parse(apiTunnels: tunnels, port: 47616)
            == .running(address: "https://my-mac-example.ngrok-free.app", port: 47616), "ngrok to the port")
        #expect(NgrokStatus.parse(apiTunnels: tunnels, port: 47626)
            == .wrongPort(port: 8080, address: "https://wiki-example.ngrok-free.app"), "ngrok elsewhere")
        #expect(NgrokStatus.parse(apiTunnels: try Self.fixture("ngrok-empty.json"), port: 47616)
            == .notRunning(reason: .noTunnel), "no tunnels")
        #expect(NgrokStatus.parse(apiTunnels: nil, port: 47616) == .unknown, "no answer")
        for addr in ["http://localhost:47616", "localhost:47616", "47616", "127.0.0.1:47616", "http://127.0.0.1:47616/"] {
            #expect(ToolJSON.localPort(addr) == 47616, "\(addr)")
        }
        for addr in ["http://example.com:47616", "file:///tmp", "localhost", "70000", "http_status:404"] {
            #expect(ToolJSON.localPort(addr) == nil, "\(addr)")
        }
    }

    @Test("tunnel processes' arguments")
    func processes() {
        #expect(TunnelProcess.cloudflaredURLPort(["cloudflared", "tunnel", "--url=http://localhost:47626"]) == 47626,
                "--url=")
        #expect(TunnelProcess.cloudflaredURLPort(["cloudflared", "tunnel", "run", "x"]) == nil, "named")
        #expect(TunnelProcess.ngrokPort(["ngrok", "http", "47616", "--url", "https://x.ngrok-free.app"]) == 47616,
                "ngrok port")
        #expect(TunnelProcess.ngrokPort(["ngrok", "http", "--url", "https://x.ngrok-free.app", "localhost:47616"])
            == nil, "a flag value isn't the port")
        #expect(TunnelProcess.cloudflaredConfig(["cloudflared", "--config", "/tmp/c.yml", "tunnel", "run"])
            == "/tmp/c.yml", "--config")
    }

    // MARK: The Tunnel row

    @Test("the Tunnel row's name: the tunnel that answered, then the address, then the choice")
    func labels() {
        // By domain.
        #expect(TunnelProvider.detect(address: "https://my-mac.tail1234.ts.net") == .tailscaleFunnel, ".ts.net")
        #expect(TunnelProvider.detect(address: "https://quiet-river-1234.trycloudflare.com") == .cloudflareQuick,
                "quick")
        #expect(TunnelProvider.detect(address: "https://my-mac-example.ngrok-free.app") == .ngrok, "ngrok")
        #expect(TunnelProvider.detect(address: "https://mcp.example.com") == nil, "own domain")
        #expect(TunnelProvider.detect(address: nil) == nil, "no address")
        // D4: the tunnel that answered, then the address, then the choice.
        func resolve(_ lastTested: TunnelProvider?, _ address: String?, _ stored: TunnelProvider) -> TunnelProvider {
            TunnelLabel.resolve(lastTested: lastTested, address: address, stored: stored)
        }
        #expect(resolve(.cloudflareTunnel, "https://my-mac.tail1234.ts.net", .tailscaleFunnel) == .cloudflareTunnel,
                "tested first")
        #expect(resolve(nil, "https://my-mac.tail1234.ts.net", .cloudflareTunnel) == .tailscaleFunnel,
                "the address beats a stale choice (the snap-back bug)")
        #expect(resolve(nil, "https://mcp.example.com", .cloudflareTunnel) == .cloudflareTunnel, "own domain: the choice")
        #expect(resolve(.other, "https://mcp.example.com", .ngrok) == .ngrok, "an unrecognized answer keeps the choice")
        #expect(resolve(.other, "https://my-mac.tail1234.ts.net", .ngrok) == .tailscaleFunnel,
                "…but not over the address")
        #expect(resolve(.other, "https://mcp.example.com", .other) == .other, "Other stays Other")
        #expect(resolve(nil, nil, .ngrok) == .ngrok, "nothing else: the choice")
        #expect(TunnelProvider(wireName: "Cloudflare quick tunnel") == .cloudflareQuick
            && TunnelProvider(wireName: nil) == nil, "by wire name")
    }

    @Test("what each state means: tone, warning, start command, tunnel down, install links")
    func states() {
        let running = TunnelHealth.running(address: "https://my-mac.tail1234.ts.net", port: 47616)
        #expect(running.tone == .ok && !running.warns, "running")
        let wrong = TunnelHealth.wrongPort(port: 47615, address: nil)
        #expect(wrong.warns, "wrong port")
        let stopped = TunnelHealth.notRunning(reason: .noTunnel)
        #expect(stopped.warns && stopped.showsStartCommand, "not running")
        #expect(!TunnelHealth.notRunning(reason: .loggedOut).showsStartCommand, "logged out: log in first")
        #expect(!TunnelHealth.notInstalled.warns, "not installed")
        #expect(TunnelHealth.unknown.tone == .neutral && !TunnelHealth.unknown.warns, "can't check")
        // Tunnel down (D10): only while Remote Access is on with an address.
        #expect(TunnelHealth.isDown(remoteActive: true, health: stopped), "down")
        #expect(!TunnelHealth.isDown(remoteActive: false, health: stopped), "not while off")
        #expect(!TunnelHealth.isDown(remoteActive: true, health: .unknown)
            && !TunnelHealth.isDown(remoteActive: true, health: nil)
            && !TunnelHealth.isDown(remoteActive: true, health: .notInstalled), "can't tell isn't down")
        #expect(TunnelHealth.isDown(remoteActive: true, health: wrong), "wrong port is down")
        // Install links.
        #expect(TunnelProvider.tailscaleFunnel.installLink == "https://tailscale.com/download/mac"
            && TunnelProvider.ngrok.installLink == "https://ngrok.com/download", "links")
    }

    @Test("the reported address, the state codes and tool URLs as origins")
    func addressesAndCodes() {
        #expect(TunnelHealth.running(address: "https://a.ts.net", port: 47616).address == "https://a.ts.net")
        #expect(TunnelHealth.wrongPort(port: 8080, address: "https://b.example").address == "https://b.example")
        #expect(TunnelHealth.notPublic(address: "https://c.ts.net").address == "https://c.ts.net")
        #expect(TunnelHealth.notRunning(reason: .noTunnel).address == nil && TunnelHealth.unknown.address == nil)
        #expect(TunnelHealth.running(address: nil, port: 47616).code == "running")
        #expect(TunnelHealth.wrongPort(port: 1, address: nil).code == "wrongPort")
        #expect(TunnelHealth.notPublic(address: nil).code == "notPublic")
        #expect(TunnelHealth.notRunning(reason: .loggedOut).code == "notRunning.loggedOut")
        #expect(TunnelHealth.notRunning(reason: .funnelNotAllowed).code == "notRunning.funnelNotAllowed")
        #expect(TunnelHealth.notInstalled.code == "notInstalled" && TunnelHealth.unknown.code == "unknown")
        #expect(RemoteOriginText.normalized(" https://MCP.example.com/x ") == "https://mcp.example.com")
        #expect(RemoteOriginText.normalized("https://my-mac.tail1234.ts.net:8443") == "https://my-mac.tail1234.ts.net:8443")
        #expect(RemoteOriginText.normalized("http://mcp.example.com") == nil && RemoteOriginText.normalized("") == nil)
    }

    // MARK: Checks and step 2

    @Test("the check schedule: 60 s while on, 3 s while waiting, never while off")
    func schedule() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func interval(_ on: Bool, _ waiting: Bool) -> TimeInterval? {
            TunnelCheckSchedule.interval(remoteOn: on, waitingForTunnel: waiting)
        }
        #expect(interval(false, false) == nil && interval(false, true) == nil, "nothing while Remote Access is off")
        #expect(interval(true, false) == 60 && interval(true, true) == 3, "60 s while on, 3 s while waiting in step 2")
        func due(_ last: Date?, _ seconds: TimeInterval?) -> Bool {
            TunnelCheckSchedule.isDue(lastCheck: last, now: now, interval: seconds)
        }
        #expect(due(nil, 60) && !due(nil, nil), "first check")
        #expect(!due(now.addingTimeInterval(-59), 60) && due(now.addingTimeInterval(-60), 60), "60 s")
        #expect(!due(now.addingTimeInterval(-2.9), 3) && due(now.addingTimeInterval(-3), 3), "3 s")
        #expect(due(now.addingTimeInterval(30), 60), "a clock that went back")
        #expect(!due(now.addingTimeInterval(-3600), nil), "never while off")
    }

    @Test("step 2 while the tunnel starts, and the hostnames typed there")
    func startStep() {
        func make(_ on: Bool, _ provider: TunnelProvider, _ health: TunnelHealth?) -> TunnelStartState {
            TunnelStartState.make(remoteOn: on, provider: provider, health: health)
        }
        let running = TunnelHealth.running(address: "https://quiet-river-1234.trycloudflare.com", port: 47616)
        #expect(make(false, .tailscaleFunnel, running) == .turnOn, "off: turn on first")
        #expect(make(true, .tailscaleFunnel, nil) == .waiting, "not checked yet")
        #expect(make(true, .tailscaleFunnel, .notRunning(reason: .noTunnel)) == .waiting, "waiting")
        #expect(make(true, .cloudflareQuick, running) == .found(address: "https://quiet-river-1234.trycloudflare.com"),
                "found")
        #expect(make(true, .tailscaleFunnel, .wrongPort(port: 47615, address: nil))
            == .problem(.wrongPort(port: 47615, address: nil)), "wrong port stays")
        #expect(make(true, .tailscaleFunnel, .notRunning(reason: .loggedOut))
            == .problem(.notRunning(reason: .loggedOut)), "logged out stays with the reason")
        #expect(make(true, .other, running) == .cantCheck(nil), "Other is never checked")
        #expect(make(true, .ngrok, .notInstalled).offersStarted && make(true, .ngrok, .unknown).offersStarted,
                "I've Started It")
        #expect(!make(true, .ngrok, nil).offersStarted && !make(true, .ngrok, running).offersStarted,
                "…only when it can't tell")
        // Once per entry into step 2; Continue after Back.
        let found = make(true, .cloudflareQuick, running)
        #expect(found.autoAdvances(advancedThisEntry: false) && !found.autoAdvances(advancedThisEntry: true), "once")
        #expect(found.offersContinue && !TunnelStartState.waiting.autoAdvances(advancedThisEntry: false), "Continue")
        // Hostnames typed into step 2.
        #expect(TunnelProvider.hostname(" https://MCP.example.com/ ") == "mcp.example.com", "scheme and slash dropped")
        #expect(TunnelProvider.hostname("my name.example.com") == nil && TunnelProvider.hostname("localhost") == nil,
                "not a hostname")
        #expect(TunnelProvider.cloudflareTunnel.asksForHostname && TunnelProvider.ngrok.asksForHostname
            && !TunnelProvider.cloudflareQuick.asksForHostname, "who asks")
    }
}
