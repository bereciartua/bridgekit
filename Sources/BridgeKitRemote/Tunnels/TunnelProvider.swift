import Foundation

/// The tunnels Remote Access knows. The kit tells them apart (by the headers a
/// request arrives with, and by what an address looks like); each app words
/// them and supplies their commands, so the names here are the wire names only.
public enum TunnelProvider: String, CaseIterable, Identifiable, Sendable {
    case tailscaleFunnel, cloudflareTunnel, ngrok, cloudflareQuick, other

    public var id: String { rawValue }

    /// The name the health route reports (`"tunnel"`) and `init(wireName:)`
    /// reads back. Stable English; apps show their own words.
    public var wireName: String {
        switch self {
        case .tailscaleFunnel: "Tailscale Funnel"
        case .cloudflareTunnel: "Cloudflare Tunnel"
        case .ngrok: "ngrok"
        case .cloudflareQuick: "Cloudflare quick tunnel"
        case .other: "Other"
        }
    }

    public init?(wireName: String?) {
        guard let wireName, let provider = Self.allCases.first(where: { $0.wireName == wireName }) else {
            return nil
        }
        self = provider
    }

    /// Tailscale can't rewrite Host. An unknown tunnel may not either, so ask for the hostname.
    public var preservesHost: Bool { self == .tailscaleFunnel || self == .other }

    /// The request header that identifies the provider in Activity. ngrok adds none of its own, only
    /// X-Forwarded-Host, which names an ngrok domain unless you bring your own.
    public var detectionHeader: String? {
        switch self {
        case .tailscaleFunnel: return "Tailscale-Funnel-Request"
        case .cloudflareTunnel, .cloudflareQuick: return "CF-Ray"
        case .ngrok: return "X-Forwarded-Host"
        case .other: return nil
        }
    }

    public static let ngrokDomains = [".ngrok-free.app", ".ngrok-free.dev", ".ngrok.app", ".ngrok.dev", ".ngrok.io"]

    /// For Activity's "tunnel: …". Display only: anything on the Mac can send these headers.
    public static func detect(headers: [(String, String)]) -> TunnelProvider? {
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

    /// What the address looks like: `.ts.net` is Tailscale Funnel,
    /// `.trycloudflare.com` a quick tunnel, ngrok's domains ngrok. Nil when it
    /// could be anything (a Cloudflare Tunnel or ngrok on your own domain).
    public static func detect(address: String?) -> TunnelProvider? {
        guard let host = address.flatMap(URL.init(string:))?.host?.lowercased() else { return nil }
        if host.hasSuffix(".ts.net") { return .tailscaleFunnel }
        if host.hasSuffix(".trycloudflare.com") { return .cloudflareQuick }
        if ngrokDomains.contains(where: { host.hasSuffix($0) }) { return .ngrok }
        return nil
    }

    /// Where to get the tool, for Not installed.
    public var installLink: String? {
        switch self {
        case .tailscaleFunnel: "https://tailscale.com/download/mac"
        case .ngrok: "https://ngrok.com/download"
        case .cloudflareTunnel, .cloudflareQuick, .other: nil
        }
    }

    /// Cloudflare Tunnel and ngrok ask for the hostname first; the commands
    /// and config.yml use it, never the address in use.
    public var asksForHostname: Bool { self == .cloudflareTunnel || self == .ngrok }

    public var hostnamePlaceholder: String { self == .ngrok ? "<your-dev-domain>" : "mcp.example.com" }

    /// The hostname a typed value means: no scheme, path or spaces.
    public static func hostname(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        value = String(value.prefix { $0 != "/" })
        guard !value.isEmpty, !value.contains(" "), value.contains(".") else { return nil }
        return value
    }
}
