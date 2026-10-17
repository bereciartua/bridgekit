import Darwin
import Foundation

/// `mcp-endpoint.json` tells the launcher where the server listens and which
/// process owns it, so changing the port never breaks launcher setups. It
/// holds no secret. A stale file after a crash is harmless: the launcher
/// checks the listener, not the file.
public struct MCPEndpointFile: Sendable {
    public static let name = "mcp-endpoint.json"
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var url: URL { directory.appendingPathComponent(Self.name) }

    public static func endpointURL(port: Int) -> String { "http://127.0.0.1:\(port)/mcp" }

    @discardableResult
    public func write(port: Int, pid: Int32 = getpid(), startedAt: Date = Date()) -> Bool {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { return false }
        guard (try? SafePath.checkDirectory(directory.path)) != nil else { return false }
        let object: [String: Any] = [
            "version": 1, "url": Self.endpointURL(port: port), "port": port,
            "pid": Int(pid), "startedAt": Int(startedAt.timeIntervalSince1970),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return false }
        return SafePath.atomicWrite(data, to: url.path)
    }

    /// Removes the file only if this process wrote it, so a second copy of
    /// the app can't break the running copy's launcher setups.
    public func remove(pid: Int32 = getpid()) {
        guard let data = try? SafePath.readFile(url.path, maxBytes: 4_096),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["pid"] as? Int == Int(pid) else { return }
        unlink(url.path)
    }
}
