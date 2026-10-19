import Foundation

/// The paths Remote Access answers, in one place for the gate, the OAuth server and the tunnel
/// commands: the secret prefix (MCP, health, sign-in, token, and the OpenID document under it),
/// and the three discovery documents, which insert the secret prefix after their well-known name
/// (RFC 9728, RFC 8414, OpenID Connect Discovery). Nothing outside these is ever answered.
public enum RemotePaths {
    public static let protectedResource = "oauth-protected-resource"
    public static let authorizationServer = "oauth-authorization-server"
    public static let openIDConfiguration = "openid-configuration"
    public static let discoveryDocuments = [protectedResource, authorizationServer, openIDConfiguration]

    /// `/r/<secret>`, then each discovery document's `/.well-known/<name>/r/<secret>`.
    public static func paths(secretPrefix: String) -> [String] {
        [secretPrefix] + discoveryDocuments.map { "/.well-known/" + $0 + secretPrefix }
    }

    /// Whether `path` is one of `paths` or below it, by whole segment: `/r/abc` covers
    /// `/r/abc/mcp` but not `/r/abcd`, as Tailscale matches its path entries.
    public static func covers(_ paths: [String], _ path: String) -> Bool {
        paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
