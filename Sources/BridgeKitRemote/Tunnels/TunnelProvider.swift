import Foundation

}

// MARK: - Tunnels (§22.5)

enum TunnelProvider: String, CaseIterable, Identifiable {
    case tailscaleFunnel, cloudflareTunnel, ngrok, cloudflareQuick, other

    var id: String { rawValue }

    static let defaultRemotePort = 47616
    static let cloudflareTunnelName = "ek-bridge"

    var displayName: String {
        switch self {
        case .tailscaleFunnel: return String(localized: "Tailscale Funnel (recommended)")
        case .cloudflareTunnel: return String(localized: "Cloudflare Tunnel (your own domain)")
        case .ngrok: return String(localized: "ngrok")
        case .cloudflareQuick: return String(localized: "Cloudflare quick tunnel (testing only)")
        case .other: return String(localized: "Other tunnel")
        }
    }

    /// The plain name, for chips, Activity and the Test result.
    var name: String {
        switch self {
        case .tailscaleFunnel: return String(localized: "Tailscale Funnel")
        case .cloudflareTunnel: return String(localized: "Cloudflare Tunnel")
        case .ngrok: return String(localized: "ngrok")
        case .cloudflareQuick: return String(localized: "Cloudflare quick tunnel")
        case .other: return String(localized: "Other")
        }
    }

    /// One line for the guide's tunnel choice.
    var summary: String {
        switch self {
        case .tailscaleFunnel:
            return String(localized: "Free; TLS ends on this Mac. Needs Tailscale installed and signed in.")
        case .cloudflareTunnel:
            return String(localized: "Free with your own domain on Cloudflare. TLS ends at Cloudflare.")
        case .ngrok:
            return String(localized: "A free dev domain with an ngrok account. TLS ends at ngrok.")
        case .cloudflareQuick:
            return String(localized: "No account, but a random address each time. For testing only.")
        case .other:
            return String(localized: "Any HTTPS tunnel that forwards to the Remote Access port.")
        }
    }

    /// Start commands, then `offCommands`, to run in order in Terminal.
    func commands(port: Int, hostname: String?) -> [String] {
        let name = Self.cloudflareTunnelName
        let start: [String]
        switch self {
        case .tailscaleFunnel:
            start = ["tailscale funnel --bg \(port)"]
        case .cloudflareTunnel:
            start = [
                "brew install cloudflared", "cloudflared tunnel login", "cloudflared tunnel create \(name)",
                "cloudflared tunnel route dns \(name) \(hostname ?? "mcp.example.com")",
                "cloudflared tunnel run \(name)",
            ]
        case .ngrok:
            start = [
                "ngrok config add-authtoken <your ngrok authtoken>",
                "ngrok http \(port) --url https://\(hostname ?? "<your-dev-domain>") --host-header=rewrite",
            ]
        case .cloudflareQuick:
            // Without the rewrite, the random trycloudflare.com Host fails the remote Host check.
            start = ["cloudflared tunnel --url http://127.0.0.1:\(port) --http-host-header 127.0.0.1:\(port)"]
        case .other:
            start = []
        }
        return start + offCommands(port: port)
    }

    /// Only Funnel keeps running in the background; the others stop with Control-C.
    func offCommands(port: Int) -> [String] {
        self == .tailscaleFunnel ? ["tailscale funnel --bg \(port) off"] : []
    }

    /// `~/.cloudflared/config.yml` for a named Cloudflare tunnel.
    func configFile(port: Int, hostname: String?) -> String? {
        guard self == .cloudflareTunnel else { return nil }
        return """
            tunnel: \(Self.cloudflareTunnelName)
            credentials-file: ~/.cloudflared/<tunnel-UUID>.json
            ingress:
              - hostname: \(hostname ?? "mcp.example.com")
                service: http://127.0.0.1:\(port)
                originRequest:
                  httpHostHeader: "127.0.0.1:\(port)"
              - service: http_status:404
            """
    }

    var steps: [String] {
        let paste = { (address: String) in
            String(localized: "Paste \(address) in step 3.")
        }
        let controlC = { (tool: String) in
            String(localized: "To turn it off, press Control-C in the Terminal window running \(tool).")
        }
        switch self {
        case .tailscaleFunnel:
            return [
                String(localized: "Install Tailscale on this Mac and sign in."),
                String(localized: """
                    In the Tailscale admin console, turn on MagicDNS and HTTPS certificates, and add the \
                    funnel node attribute to your tailnet policy.
                    """),
                String(localized: """
                    Run the first command in Terminal. Funnel prints your public address, such as \
                    https://my-mac.tail1234.ts.net.
                    """),
                paste(String(localized: "that address"))
                    + " " + String(localized: "Public DNS can take about 10 minutes the first time."),
                String(localized: "To turn it off, run the last command."),
            ]
        case .cloudflareTunnel:
            return [
                String(localized: "You need a domain on Cloudflare. The login command opens your browser."),
                String(localized: """
                    Before you run the tunnel, save the configuration as ~/.cloudflared/config.yml, with \
                    <tunnel-UUID> replaced by the ID that tunnel create printed.
                    """),
                paste(String(localized: "https:// and your hostname")), controlC("cloudflared"),
            ]
        case .ngrok:
            return [
                String(localized: """
                    Sign up at ngrok.com, then put your authtoken and your free dev domain from the \
                    dashboard into the commands.
                    """),
                paste(String(localized: "https:// and your dev domain")), controlC("ngrok"),
            ]
        case .cloudflareQuick:
            return [
                String(localized: """
                    Run the command. cloudflared prints a random https://….trycloudflare.com address.
                    """),
                paste(String(localized: "that address")), controlC("cloudflared"),
            ]
        case .other:
            return [
                String(localized: """
                    Point the tunnel at http://127.0.0.1 and the Remote Access port, never at the port \
                    local agents use.
                    """),
                String(localized: """
                    Have it rewrite Host to 127.0.0.1 and the port, or keep its public hostname, which \
                    must then be the address you paste.
                    """),
                paste(String(localized: "its HTTPS address")),
            ]
        }
    }

    var notes: [String] {
        let edge = { (provider: String) in
            String(localized: """
                TLS ends at \(provider)'s edge, so \(provider) can read the traffic, calendar data \
                included.
                """)
        }
        switch self {
        case .tailscaleFunnel:
            return [
                String(localized: """
                    TLS ends on this Mac, inside Tailscale, so the relays in between can't read the traffic.
                    """),
                String(localized: """
                    Funnel keeps the public hostname in Host, so it must match Address.
                    """),
                String(localized: "Tailscale Serve isn't enough: cloud agents aren't on your tailnet."),
                String(localized: """
                    Funnel keeps running in the background, even after a restart, until you turn it off.
                    """),
            ]
        case .cloudflareTunnel:
            return [
                edge("Cloudflare"),
                String(localized: "The configuration rewrites Host to this Mac's address."),
                String(localized: """
                    Optionally, put Cloudflare Access service tokens in front for agents that can send \
                    two extra headers, such as Cursor, Copilot and Devin.
                    """),
            ]
        case .ngrok:
            return [
                edge("ngrok"),
                String(localized: "The free plan allows 20,000 requests a month."),
                String(localized: """
                    Don't turn on ngrok's basic auth: it takes over the Authorization header that carries \
                    the token.
                    """),
                String(localized: """
                    Optionally, allow only your agent's addresses with a Traffic Policy IP restriction, \
                    for example Anthropic's 160.79.104.0/21.
                    """),
            ]
        case .cloudflareQuick:
            return [
                String(localized: """
                    For testing only: the address changes every time it starts, which breaks every cloud \
                    agent you set up.
                    """),
                edge("Cloudflare"),
            ]
        case .other:
            return [
                String(localized: "The tunnel must pass the Authorization header through unchanged."),
                String(localized: "If TLS ends at the provider's edge, the provider can read the traffic."),
            ]
        }
    }

    /// Tailscale can't rewrite Host. An unknown tunnel may not either, so ask for the hostname.
    var preservesHost: Bool { self == .tailscaleFunnel || self == .other }

    /// The request header that identifies the provider in Activity. ngrok adds none of its own, only
    /// X-Forwarded-Host, which names an ngrok domain unless you bring your own.
    var detectionHeader: String? {
        switch self {
        case .tailscaleFunnel: return "Tailscale-Funnel-Request"
        case .cloudflareTunnel, .cloudflareQuick: return "CF-Ray"
        case .ngrok: return "X-Forwarded-Host"
        case .other: return nil
        }
    }

    static let ngrokDomains = [".ngrok-free.app", ".ngrok-free.dev", ".ngrok.app", ".ngrok.dev", ".ngrok.io"]

    /// For Activity's "tunnel: …". Display only: anything on the Mac can send these headers.
    static func detect(headers: [(String, String)]) -> TunnelProvider? {
        func value(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1.lowercased()
        }
        let forwardedHost = value("X-Forwarded-Host") ?? ""
        if value("Tailscale-Funnel-Request") != nil { return .tailscaleFunnel }
        if value("CF-Ray") != nil {
            // A quick tunnel whose Host was rewritten looks like a named one.
            let hosts = [forwardedHost, value("Host") ?? ""].map { $0.split(separator: ":").first ?? "" }
            return hosts.contains { $0.hasSuffix(".trycloudflare.com") } ? .cloudflareQuick : .cloudflareTunnel
        }
        let bareHost = forwardedHost.split(separator: ":").first ?? ""
        if ngrokDomains.contains(where: { bareHost.hasSuffix($0) }) { return .ngrok }
        if ["X-Forwarded-For", "X-Forwarded-Host", "Forwarded"].contains(where: { value($0) != nil }) {
            return .other
        }
        return nil
    }
