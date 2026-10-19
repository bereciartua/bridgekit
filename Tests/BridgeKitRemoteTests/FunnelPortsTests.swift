import Foundation
import Testing
@testable import BridgeKitRemote

/// Several apps sharing Tailscale Funnel on one Mac: which public port Remote Access uses, what's
/// in the way, and the commands for that port. No app may offer a command that replaces another
/// app's entry.
@Suite("Funnel ports")
struct FunnelPortsTests {
    static func ports(_ fixture: String, port: Int) throws -> FunnelPorts {
        try #require(FunnelPorts.parse(funnel: try TunnelHealthTests.fixture(fixture), port: port))
    }

    @Test("the first free public port, in the order 443, 8443, 10000")
    func choice() throws {
        let none = try Self.ports("tailscale-funnel-none.json", port: 47627)
        #expect(none.entries.isEmpty && none.publicPort == 443 && none.inTheWay.isEmpty, "nothing served: 443")
        // EK Bridge's Funnel on 443: the next app takes 8443.
        let ekOnly = try Self.ports("tailscale-funnel-wrong-port.json", port: 47627)
        #expect(ekOnly.publicPort == 8443, "443 taken: 8443")
        #expect(ekOnly.inTheWay.map(\.publicPort) == [443] && ekOnly.inTheWay.first?.targets == [47615], "what's on 443")
        // The real config: Funnel 443 → 47616, and a tailnet-only Serve entry on 8443 → 4000.
        let real = try Self.ports("tailscale-funnel.json", port: 47627)
        #expect(real.publicPort == 10000, "a Serve entry takes its port too")
        #expect(real.inTheWay == [
            FunnelPorts.Entry(publicPort: 443, host: "my-mac.tail1234.ts.net", targets: [47616], funnel: true),
            FunnelPorts.Entry(publicPort: 8443, host: "my-mac.tail1234.ts.net", targets: [4000], funnel: false),
        ], "both in the way, with their targets")
        #expect(real.running == nil)
        // All three taken, the last by a raw TCP forwarder.
        let full = try Self.ports("tailscale-funnel-all-taken.json", port: 47627)
        #expect(full.publicPort == nil, "nothing free")
        #expect(full.inTheWay.map(\.publicPort) == [443, 8443, 10000] && full.entry(on: 10000)?.targets == [5432]
            && full.entry(on: 10000)?.host == nil, "the TCP forwarder counts")
    }

    @Test("already running wins, on whichever port")
    func running() throws {
        let tenK = try Self.ports("tailscale-funnel-10000.json", port: 47627)
        #expect(tenK.running?.publicPort == 10000 && tenK.publicPort == 10000 && tenK.inTheWay.isEmpty,
                "running on 10000: nothing else suggested")
        #expect(tenK.running?.address == "https://my-mac.tail1234.ts.net:10000")
        // EK Bridge's own view of the same Mac: still 443.
        let ek = try Self.ports("tailscale-funnel-10000.json", port: 47616)
        #expect(ek.running?.publicPort == 443 && ek.publicPort == 443, "the other app keeps its port")
        let full = try Self.ports("tailscale-funnel-all-taken.json", port: 47616)
        #expect(full.publicPort == 443 && full.running?.address == "https://my-mac.tail1234.ts.net",
                "running even though all three are served")
        // Serve without Funnel on our port: turning Funnel on there is the fix, not another port.
        let serveOnly = try Self.ports("tailscale-funnel-serve-only.json", port: 47616)
        #expect(serveOnly.running == nil && serveOnly.publicPort == 443, "our own Serve entry's port")
    }

    @Test("unreadable output gives no ports")
    func unreadable() {
        #expect(FunnelPorts.parse(funnel: nil, port: 47627) == nil)
        #expect(FunnelPorts.parse(funnel: Data("not json".utf8), port: 47627) == nil)
    }

    @Test("the check's answer carries the ports for Tailscale only when it could read them")
    func result() throws {
        let status = try TunnelHealthTests.fixture("tailscale-status.json")
        let funnel = try TunnelHealthTests.fixture("tailscale-funnel.json")
        let result = TailscaleStatus.result(status: status, funnel: funnel, port: 47627)
        #expect(result.health == .notRunning(reason: .noTunnel) && result.funnel?.publicPort == 10000)
        #expect(TailscaleStatus.result(status: status, funnel: nil, port: 47627) == TunnelCheckResult(health: .unknown),
                "no funnel status: no ports")
        let loggedOut = TailscaleStatus.result(status: try TunnelHealthTests.fixture("tailscale-status-logged-out.json"),
                                               funnel: funnel, port: 47627)
        #expect(loggedOut.health == .notRunning(reason: .loggedOut))
    }

    @Test("all ports taken: a problem, with no start command")
    func allTakenState() {
        let health = TunnelHealth.notRunning(reason: .allPortsTaken)
        #expect(health.warns && !health.showsStartCommand && health.code == "notRunning.allPortsTaken")
        #expect(TunnelStartState.make(remoteOn: true, provider: .tailscaleFunnel, health: health) == .problem(health))
    }

    @Test("commands for each public port; 443 keeps the short form")
    func commands() {
        #expect(TailscaleFunnelCommand.start(port: 47616) == "tailscale funnel --bg 47616")
        #expect(TailscaleFunnelCommand.off(port: 47616) == "tailscale funnel --bg 47616 off")
        #expect(TailscaleFunnelCommand.start(port: 47627, publicPort: 8443) == "tailscale funnel --bg --https=8443 47627")
        #expect(TailscaleFunnelCommand.off(port: 47627, publicPort: 8443) == "tailscale funnel --https=8443 off")
        #expect(TailscaleFunnelCommand.start(port: 47627, publicPort: 10000) == "tailscale funnel --bg --https=10000 47627")
        #expect(TailscaleFunnelCommand.publicPort(fromAddress: "https://my-mac.tail1234.ts.net") == 443)
        #expect(TailscaleFunnelCommand.publicPort(fromAddress: "https://my-mac.tail1234.ts.net:8443") == 8443)
        #expect(TailscaleFunnelCommand.publicPort(fromAddress: nil) == 443)
    }
}
