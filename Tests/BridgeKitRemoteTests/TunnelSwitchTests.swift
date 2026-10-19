import Foundation
import Testing
@testable import BridgeKitRemote

/// Plan 08 T06, T07: Switch Tunnel… and Address ▸ Edit…, step by step; the confirmation's lists;
/// remembered addresses. The steps' titles are the app's words and are tested there.
@Suite("Tunnel switch")
struct TunnelSwitchTests {
    static let funnel = "https://my-mac.tail1234.ts.net"
    static let quick = "https://quiet-river-1234.trycloudflare.com"

    /// The apps' off commands: only Funnel keeps running in the background, on the address's port.
    static func offCommands(_ provider: TunnelProvider, _ port: Int, _ origin: String) -> [String] {
        provider == .tailscaleFunnel
            ? [TailscaleFunnelCommand.off(port: port, publicPort: TailscaleFunnelCommand.publicPort(fromAddress: origin))]
            : []
    }

    static func summary(_ change: TunnelSwitch, newOrigin: String, remoteTokenClients: [String],
                        oauthApps: [String]) -> TunnelSwitchSummary {
        TunnelSwitchSummary.make(change, newOrigin: newOrigin, port: 47616, remoteTokenClients: remoteTokenClients,
                                 oauthApps: oauthApps, offCommands: offCommands)
    }

    @Test("Switch Tunnel… goes Choose · Start it · Paste and test · Switch; Edit… starts at the test")
    func steps() {
        var change = TunnelSwitch(kind: .switchTunnel, fromTunnel: .tailscaleFunnel, fromOrigin: Self.funnel)
        #expect(change.step == .choose && change.steps == [.choose, .start, .test, .confirm], "starts at Choose")
        #expect(!change.canChoose(.tailscaleFunnel) && change.canChoose(.cloudflareQuick) && change.canChoose(.other),
                "the tunnel in use can't be picked")
        change.picked = .cloudflareQuick
        #expect(change.step == .start, "Start it")
        change.started = true
        #expect(change.step == .test, "Paste and test")
        change.confirming = true
        #expect(change.step == .confirm, "Switch")
        // Edit…: the same tunnel, at step 3, with the address in use.
        let edit = TunnelSwitch(kind: .editAddress, fromTunnel: .cloudflareQuick, fromOrigin: Self.quick)
        #expect(edit.step == .test && edit.picked == .cloudflareQuick && edit.address == Self.quick
            && edit.addressSource == .inUse, "Edit… opens at Paste and test")
        #expect(edit.steps == [.test, .confirm], "Paste and test · Save")
        // Step 3's address: the running tunnel's, then the remembered one.
        #expect(TunnelSwitch.prefill(found: Self.quick, remembered: "https://old.trycloudflare.com")
            == (Self.quick, .runningTunnel), "running tunnel first")
        #expect(TunnelSwitch.prefill(found: nil, remembered: Self.quick) == (Self.quick, .remembered),
                "then remembered")
        #expect(TunnelSwitch.prefill(found: nil, remembered: nil) == ("", .none), "else empty")
    }

    @Test("Switch only after the address in the field passed the test; another tunnel answering")
    func tests() {
        let quick = Self.quick
        var change = TunnelSwitch(kind: .switchTunnel, fromTunnel: .tailscaleFunnel, fromOrigin: Self.funnel)
        change.picked = .cloudflareQuick
        change.started = true
        #expect(!change.canConfirm(normalized: quick), "not before a test")
        change.test = .testing(address: quick)
        #expect(!change.canConfirm(normalized: quick), "not while testing")
        change.test = .notReachable(address: quick, reason: "No answer.")
        #expect(!change.canConfirm(normalized: quick), "not when it failed")
        change.test = .reachable(address: quick, ms: 84, tunnel: .cloudflareQuick)
        #expect(change.canConfirm(normalized: quick) && change.otherTunnel == nil,
                "reachable through the picked tunnel")
        #expect(!change.canConfirm(normalized: "https://edited.trycloudflare.com")
            && change.result(for: "https://edited.trycloudflare.com") == .notTested,
                "an edited address needs a new test")
        #expect(!change.canConfirm(normalized: nil), "an invalid address")
        // Another tunnel answered.
        change.test = .reachable(address: quick, ms: 84, tunnel: .tailscaleFunnel)
        #expect(change.otherTunnel == .tailscaleFunnel, "says which tunnel answered")
        change.test = .reachable(address: quick, ms: 84, tunnel: .other)
        #expect(change.otherTunnel == nil, "an unrecognized tunnel says nothing")
        change.picked = .other
        change.test = .reachable(address: quick, ms: 84, tunnel: .cloudflareQuick)
        #expect(change.otherTunnel == nil, "Other tunnel means any tunnel")
        // Nothing would change: the same address through the same tunnel.
        var edit = TunnelSwitch(kind: .editAddress, fromTunnel: .cloudflareQuick, fromOrigin: quick)
        edit.test = .reachable(address: quick, ms: 50, tunnel: .cloudflareQuick)
        #expect(!edit.canConfirm(normalized: quick), "the address in use isn't a change")
        edit.test = .reachable(address: "https://new-name-77.trycloudflare.com", ms: 50, tunnel: .cloudflareQuick)
        #expect(edit.canConfirm(normalized: "https://new-name-77.trycloudflare.com"), "a new quick-tunnel address")
    }

    @Test("the confirmation: the new URL, who needs it, who's disconnected, what to stop")
    func summary() {
        var change = TunnelSwitch(kind: .switchTunnel, fromTunnel: .tailscaleFunnel, fromOrigin: Self.funnel)
        change.picked = .cloudflareQuick
        let full = Self.summary(change, newOrigin: Self.quick, remoteTokenClients: ["Claude Code"],
                                oauthApps: ["claude.ai"])
        #expect(full.tunnel == .cloudflareQuick)
        #expect(full.mcpURL == Self.quick + "/r/••••••/mcp", "the new URL, secret hidden")
        #expect(full.updateURLIn == ["Claude Code"] && full.disconnected == ["claude.ai"] && !full.noCloudAgents,
                "names")
        #expect(full.stopTunnel == .tailscaleFunnel && full.stopCommands == ["tailscale funnel --bg 47616 off"],
                "then you can stop Tailscale Funnel")
        // Funnel on 8443 (another app has 443): only that port is turned off.
        var shared = TunnelSwitch(kind: .switchTunnel, fromTunnel: .tailscaleFunnel, fromOrigin: Self.funnel + ":8443")
        shared.picked = .cloudflareQuick
        #expect(Self.summary(shared, newOrigin: Self.quick, remoteTokenClients: [], oauthApps: []).stopCommands
            == ["tailscale funnel --https=8443 off"], "the off command for the address's port")
        let none = Self.summary(change, newOrigin: Self.quick, remoteTokenClients: [], oauthApps: [])
        #expect(none.noCloudAgents, "No cloud agents use the current URL yet")
        // Quick tunnel → Tailscale: nothing to stop (Control-C).
        var back = TunnelSwitch(kind: .switchTunnel, fromTunnel: .cloudflareQuick, fromOrigin: Self.quick)
        back.picked = .tailscaleFunnel
        let reverse = Self.summary(back, newOrigin: Self.funnel, remoteTokenClients: ["A"], oauthApps: [])
        #expect(reverse.stopTunnel == nil && reverse.stopCommands.isEmpty, "no off command")
        // The same address through another tunnel: the URL stays.
        let same = Self.summary(change, newOrigin: Self.funnel, remoteTokenClients: ["Claude Code"],
                                oauthApps: ["claude.ai"])
        #expect(same.noCloudAgents, "nothing to update")
        // Edit… never suggests stopping the tunnel in use.
        let edit = TunnelSwitch(kind: .editAddress, fromTunnel: .tailscaleFunnel, fromOrigin: Self.funnel)
        #expect(Self.summary(edit, newOrigin: "https://other.tail1234.ts.net", remoteTokenClients: [],
                             oauthApps: []).stopTunnel == nil, "Edit… stops nothing")
    }

    @Test("each tunnel's last address, by raw value, in UserDefaults")
    func memory() throws {
        let suite = "tunnel-switch-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TunnelAddressMemory.load(defaults).isEmpty, "empty")
        TunnelAddressMemory.save([.tailscaleFunnel: Self.funnel, .cloudflareQuick: Self.quick], defaults)
        #expect(defaults.dictionary(forKey: "RemoteTunnelAddresses") as? [String: String]
            == ["tailscaleFunnel": Self.funnel, "cloudflareQuick": Self.quick], "stored by raw value")
        #expect(TunnelAddressMemory.load(defaults) == [.tailscaleFunnel: Self.funnel, .cloudflareQuick: Self.quick],
                "loaded")
        defaults.set(["tailscaleFunnel": Self.funnel, "warp": "https://x", "ngrok": "http://insecure"],
                     forKey: "RemoteTunnelAddresses")
        #expect(TunnelAddressMemory.load(defaults) == [.tailscaleFunnel: Self.funnel],
                "unknown tunnels and bad addresses dropped")
        #expect(TunnelAddressMemory.hostname("https://mcp.example.com") == "mcp.example.com"
            && TunnelAddressMemory.hostname(nil) == nil, "hostname")
        // Another app's key.
        TunnelAddressMemory.save([.ngrok: "https://x.ngrok-free.app"], defaults, key: "FunesTunnelAddresses")
        #expect(TunnelAddressMemory.load(defaults, key: "FunesTunnelAddresses") == [.ngrok: "https://x.ngrok-free.app"])
        #expect(TunnelAddressMemory.load(defaults) == [.tailscaleFunnel: Self.funnel], "the default key untouched")
    }
}
