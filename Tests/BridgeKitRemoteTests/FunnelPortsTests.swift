import Foundation
import Testing
@testable import BridgeKitRemote

/// Several apps sharing Tailscale Funnel's port 443 by path: where Remote Access runs, what's
/// missing, which port it should use, and the commands. No app may offer a command that replaces
/// another app's entry or makes a tailnet-only one public. The shapes follow `tailscale funnel
/// status --json` as Tailscale 1.102 printed it for path entries (plan "Funnel paths").
@Suite("Funnel ports")
struct FunnelPortsTests {
    static let secret = "q7Zk2vN4bXwP9sL1mT6hYa"
    static let paths = RemoteConfiguration(secret: secret, publicOrigin: nil, port: 47627).publicPaths

    static func ports(_ fixture: String, port: Int = 47627) throws -> FunnelPorts {
        try #require(FunnelPorts.parse(funnel: try TunnelHealthTests.fixture(fixture), port: port, paths: paths))
    }

    @Test("path targets keep their path; a bare trailing slash isn't one")
    func targets() {
        #expect(ToolJSON.target("http://127.0.0.1:47627/r/abc")! == (47627, "/r/abc"))
        #expect(ToolJSON.target("http://localhost:47616/")! == (47616, ""))
        #expect(ToolJSON.target("127.0.0.1:47616")! == (47616, ""))
        #expect(ToolJSON.target("47616")! == (47616, ""))
        #expect(ToolJSON.target("http://192.168.1.2:47616/r/abc") == nil, "another machine")
        #expect(ToolJSON.localPort("http://127.0.0.1:47699/r/spiketest") == 47699)
    }

    @Test("443 first: EK Bridge's / leaves it sharable, a tailnet-only entry doesn't")
    func choice() throws {
        let none = try Self.ports("tailscale-funnel-none.json")
        #expect(none.publicPort == 443 && none.reachesCloudAgents && none.pathsToAdd == Self.paths, "nothing served")
        // The real config before: Funnel 443 → EK Bridge, a tailnet-only Serve entry on 8443.
        let real = try Self.ports("tailscale-funnel.json")
        #expect(real.publicPort == 443 && real.inTheWay.isEmpty && real.running == nil && real.incomplete == nil,
                "EK Bridge's Funnel / is shared, not replaced")
        let tailnet = try Self.ports("tailscale-funnel-443-tailnet.json")
        #expect(!tailnet.sharable(443) && tailnet.publicPort == 8443 && !tailnet.reachesCloudAgents,
                "a tailnet-only 443 would become public: 8443, which claude.ai and ChatGPT don't reach")
        #expect(tailnet.inTheWay.map(\.publicPort) == [443])
        let unsharable = try Self.ports("tailscale-funnel-unsharable.json")
        #expect(unsharable.publicPort == nil && unsharable.inTheWay.map(\.publicPort) == [443, 8443, 10000]
            && unsharable.entry(on: 10000)?.tcpForward == 5432, "tailnet-only, tailnet-only, a TCP forwarder")
        // Busy 8443 and 10000 don't matter while 443 is public.
        #expect(try Self.ports("tailscale-funnel-all-taken.json").publicPort == 443)
    }

    @Test("running: all four paths, or a whole-port / from before")
    func running() throws {
        let shared = try Self.ports("tailscale-funnel-paths.json")
        #expect(shared.running?.publicPort == 443 && shared.pathsToAdd.isEmpty && shared.inTheWay.isEmpty,
                "Funes's paths beside EK Bridge's /")
        #expect(shared.running?.address == "https://my-mac.tail1234.ts.net")
        #expect(shared.ownPaths(shared.entry(on: 443)!) == Self.paths)
        let ek = try Self.ports("tailscale-funnel-paths.json", port: 47616)
        #expect(ek.running?.publicPort == 443, "EK Bridge's whole-port / still counts for EK Bridge")
        let legacy = try Self.ports("tailscale-funnel-10000.json")
        #expect(legacy.running?.publicPort == 10000 && legacy.publicPort == 10000, "a / to us, wherever it is")
        let serveOnly = try Self.ports("tailscale-funnel-serve-only.json", port: 47616)
        #expect(serveOnly.running == nil && serveOnly.publicPort == 443, "our own Serve entry's port")
    }

    @Test("incomplete: the missing paths, on the same port")
    func incomplete() throws {
        let partial = try Self.ports("tailscale-funnel-paths-incomplete.json")
        #expect(partial.running == nil && partial.incomplete?.entry.publicPort == 443)
        #expect(partial.incomplete?.missing == [Self.paths[3]] && partial.pathsToAdd == [Self.paths[3]],
                "only the OpenID discovery path is missing")
    }

    @Test("unreadable output gives no ports")
    func unreadable() {
        #expect(FunnelPorts.parse(funnel: nil, port: 47627, paths: Self.paths) == nil)
        #expect(FunnelPorts.parse(funnel: Data("not json".utf8), port: 47627, paths: Self.paths) == nil)
    }

    @Test("the check's answer carries the ports for Tailscale only when it could read them")
    func result() throws {
        let status = try TunnelHealthTests.fixture("tailscale-status.json")
        let funnel = try TunnelHealthTests.fixture("tailscale-funnel.json")
        let result = TailscaleStatus.result(status: status, funnel: funnel, port: 47627, paths: Self.paths)
        #expect(result.health == .notRunning(reason: .noTunnel) && result.funnel?.publicPort == 443)
        #expect(TailscaleStatus.result(status: status, funnel: nil, port: 47627, paths: Self.paths)
            == TunnelCheckResult(health: .unknown), "no funnel status: no ports")
    }

    @Test("incomplete and no sharable port are problems, with no generic start command")
    func states() {
        let incomplete = TunnelHealth.incomplete(address: "https://my-mac.tail1234.ts.net", missing: 1)
        #expect(incomplete.warns && !incomplete.showsStartCommand && incomplete.code == "incomplete"
            && incomplete.address == "https://my-mac.tail1234.ts.net")
        #expect(TunnelStartState.make(remoteOn: true, provider: .tailscaleFunnel, health: incomplete) == .problem(incomplete))
        let none = TunnelHealth.notRunning(reason: .noSharablePort)
        #expect(none.warns && !none.showsStartCommand && none.code == "notRunning.noSharablePort")
    }

    @Test("commands name their port and path; never a bare off")
    func commands() throws {
        let start = TailscaleFunnelCommand.start(port: 47627, paths: Self.paths)
        #expect(start.first == "tailscale funnel --bg --https=443 --set-path /r/\(Self.secret) http://127.0.0.1:47627/r/\(Self.secret)")
        #expect(start.count == 4 && start[1].contains("--set-path /.well-known/oauth-protected-resource/r/\(Self.secret) "
            + "http://127.0.0.1:47627/.well-known/oauth-protected-resource/r/\(Self.secret)"))
        #expect(TailscaleFunnelCommand.start(port: 47627, publicPort: 8443, paths: [Self.paths[0]])
            == ["tailscale funnel --bg --https=8443 --set-path /r/\(Self.secret) http://127.0.0.1:47627/r/\(Self.secret)"])
        let off = TailscaleFunnelCommand.off(paths: Self.paths)
        #expect(off.first == "tailscale funnel --https=443 --set-path /r/\(Self.secret) off")
        #expect(off.allSatisfy { $0.contains("--set-path ") }, "every off names a path")
        // The setup the check found decides: a whole-port / from before, or the paths.
        let ek = try Self.ports("tailscale-funnel-paths.json", port: 47616)
        #expect(TailscaleFunnelCommand.off(ek, address: nil, paths: ["/r/ek"]) == ["tailscale funnel --https=443 --set-path / off"],
                "EK Bridge's / is turned off by path too, so Funes's paths stay")
        let funes = try Self.ports("tailscale-funnel-paths.json")
        #expect(TailscaleFunnelCommand.off(funes, address: nil, paths: Self.paths) == off)
        #expect(TailscaleFunnelCommand.off(nil, address: "https://my-mac.tail1234.ts.net:8443", paths: [Self.paths[0]])
            == ["tailscale funnel --https=8443 --set-path /r/\(Self.secret) off"], "no check: the address's port")
        #expect(TailscaleFunnelCommand.publicPort(fromAddress: "https://my-mac.tail1234.ts.net") == 443)
        #expect(TailscaleFunnelCommand.publicPort(fromAddress: nil) == 443)
    }

    @Test("Reset Path…: the old paths off, the new ones on; nothing for a whole-port /")
    func resetPath() throws {
        let newPaths = RemoteConfiguration(secret: "Zz9Yy8Xx7Ww6Vv5Uu4Tt3S", publicOrigin: nil, port: 47627).publicPaths
        let funes = try Self.ports("tailscale-funnel-paths.json")
        let commands = TailscaleFunnelCommand.resetPath(funes, address: nil, port: 47627, oldPaths: Self.paths,
                                                        newPaths: newPaths)
        #expect(commands == TailscaleFunnelCommand.off(paths: Self.paths)
            + TailscaleFunnelCommand.start(port: 47627, paths: newPaths))
        let legacy = try Self.ports("tailscale-funnel-10000.json")
        #expect(TailscaleFunnelCommand.resetPath(legacy, address: nil, port: 47627, oldPaths: Self.paths,
                                                 newPaths: newPaths).isEmpty, "a / forwards any path")
    }
}
