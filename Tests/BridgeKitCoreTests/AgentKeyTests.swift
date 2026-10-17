import CryptoKit
import Foundation
import Testing
@testable import BridgeKitCore

/// Bearer keys: issue, shape check, digest and constant-time verify. The shape and digest cases are
/// the crypto parts of EK Bridge's registry tests (malformed keys refused, only digests stored).
@Suite("Agent keys")
struct AgentKeyTests {
    static let prefix = "ekb_mcp_v1_"

    @Test("issue: the prefix plus 64 lowercase hex digits, never twice the same")
    func issue() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let key = AgentKey.issue(prefix: Self.prefix)
            #expect(key.hasPrefix(Self.prefix))
            #expect(key.utf8.count == 75)
            let hex = key.dropFirst(Self.prefix.count)
            #expect(hex.count == 64)
            #expect(hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
            #expect(AgentKey.isValid(key, prefix: Self.prefix))
            seen.insert(key)
        }
        #expect(seen.count == 200)
        // Another prefix, another app.
        let other = AgentKey.issue(prefix: "fns_mcp_v1_")
        #expect(other.hasPrefix("fns_mcp_v1_") && AgentKey.isValid(other, prefix: "fns_mcp_v1_"))
        #expect(!AgentKey.isValid(other, prefix: Self.prefix))
        // The random part decodes to 32 bytes.
        #expect(Hex.decode(String(other.dropFirst(11)))?.count == 32)
    }

    @Test("isValid: exact length, the prefix, lowercase hex only")
    func isValid() {
        let hex = String(repeating: "0123456789abcdef", count: 4)
        let key = Self.prefix + hex
        #expect(AgentKey.isValid(key, prefix: Self.prefix))
        // Malformed shapes, as EK Bridge's registry refused them before comparing any digest.
        let p = Self.prefix
        let short = String(hex.dropLast())
        let malformed: [String] = [
            p + hex.uppercased(),
            "ekb_mcp_v2_" + hex,
            "EKB_MCP_V1_" + hex,
            p + short,
            p + hex + "0",
            p + short + "g",
            " " + p + short,
            p + short + " ",
            p + short + "\n",
            p + short + "é",
            "ekb_v1_" + String(repeating: "a", count: 64),
            p,
            hex,
            "",
        ]
        #expect(malformed[3].utf8.count == 74 && malformed[4].utf8.count == 76)
        for candidate in malformed {
            #expect(!AgentKey.isValid(candidate, prefix: Self.prefix), "\(candidate.debugDescription)")
        }
        // A multi-byte character can't stand in for a hex digit, even at the right character count.
        let multibyte: String = Self.prefix + String(hex.dropLast(2)) + "é"
        #expect(!AgentKey.isValid(multibyte, prefix: Self.prefix))
        // The empty prefix is just 64 hex digits.
        #expect(AgentKey.isValid(hex, prefix: ""))
    }

    @Test("digest is SHA-256 of the key's UTF-8 bytes")
    func digest() {
        let key = Self.prefix + String(repeating: "ab", count: 32)
        let digest = AgentKey.digest(key)
        #expect(digest.count == 32)
        #expect(digest == Data(SHA256.hash(data: Data(key.utf8))))
        // A known vector: SHA-256("abc").
        #expect(Hex.encode(AgentKey.digest("abc"))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Hex.encode(AgentKey.digest(""))
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // UTF-8, not another encoding.
        #expect(AgentKey.digest("é") == Data(SHA256.hash(data: Data([0xC3, 0xA9]))))
        #expect(AgentKey.digest(key) != AgentKey.digest(Self.prefix + String(repeating: "cd", count: 32)))
        // A presented key carries its digest.
        let presented = PresentedKey(key)
        #expect(presented.value == key && presented.digest == digest)
        // Only the digest is stored: its hex form never contains the key or its random part.
        let stored = Hex.encode(digest)
        #expect(!stored.contains(key) && !stored.contains(String(repeating: "ab", count: 32)))
        #expect(Hex.decode(stored) == digest)
    }

    @Test("matches: true only for two equal 32-byte digests")
    func matches() {
        let one = AgentKey.digest("one")
        let two = AgentKey.digest("two")
        #expect(AgentKey.matches(one, one))
        #expect(AgentKey.matches(one, Data(one)))
        #expect(!AgentKey.matches(one, two))
        #expect(!AgentKey.matches(two, one))
        // Any single differing bit.
        for index in [0, 15, 31] {
            var flipped = one
            flipped[index] ^= 0x01
            #expect(!AgentKey.matches(one, flipped), "byte \(index)")
        }
        // Wrong lengths never match, even as prefixes of each other or both empty.
        #expect(!AgentKey.matches(Data(), Data()))
        #expect(!AgentKey.matches(one.prefix(31), one.prefix(31)))
        #expect(!AgentKey.matches(one + Data([0]), one + Data([0])))
        #expect(!AgentKey.matches(one, one + Data([0])))
        #expect(!AgentKey.matches(Data(count: 16), Data(count: 16)))
        // Slices with a non-zero start index compare by content.
        let padded = Data([9]) + one
        #expect(AgentKey.matches(padded.dropFirst(), one))
    }

    @Test("firstMatch finds the right id, or nil")
    func firstMatch() {
        let keys = (0..<5).map { _ in AgentKey.issue(prefix: Self.prefix) }
        let candidates = keys.enumerated().map { (id: "agent-\($0.offset)", digest: AgentKey.digest($0.element)) }
        for (index, key) in keys.enumerated() {
            #expect(AgentKey.firstMatch(AgentKey.digest(key), in: candidates) == "agent-\(index)")
        }
        #expect(AgentKey.firstMatch(AgentKey.digest(AgentKey.issue(prefix: Self.prefix)), in: candidates) == nil)
        #expect(AgentKey.firstMatch(AgentKey.digest(keys[0]), in: [(id: "x", digest: Data())]) == nil)
        #expect(AgentKey.firstMatch(AgentKey.digest(keys[0]), in: [] as [(id: Int, digest: Data)]) == nil)
        // A replaced key stops matching; the new one matches the same id.
        var rotated = candidates
        let replacement = AgentKey.issue(prefix: Self.prefix)
        rotated[2].digest = AgentKey.digest(replacement)
        #expect(AgentKey.firstMatch(AgentKey.digest(keys[2]), in: rotated) == nil)
        #expect(AgentKey.firstMatch(AgentKey.digest(replacement), in: rotated) == "agent-2")
        // Duplicate digests: the first entry wins, whichever ids follow.
        let shared = AgentKey.digest(keys[0])
        #expect(AgentKey.firstMatch(shared, in: [(id: 7, digest: shared), (id: 8, digest: shared)]) == 7)
        // A malformed stored digest (EK's "nothex") never matches.
        #expect(AgentKey.firstMatch(shared, in: [(id: 1, digest: Data("nothex".utf8))]) == nil)
    }

    @Test("hex encoding of 32-byte values")
    func hex() {
        let bytes = Data((0..<32).map { UInt8($0 * 8) })
        let text = Hex.encode(bytes)
        #expect(text.count == 64 && text == text.lowercased())
        #expect(Hex.decode(text) == bytes)
        #expect(Hex.decode(text.uppercased()) == nil)
        #expect(Hex.decode(String(text.dropLast())) == nil)
        #expect(Hex.decode(String(text.dropLast()) + "g") == nil)
    }
}
