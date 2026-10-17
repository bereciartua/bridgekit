import Foundation
import Testing
@testable import BridgeKitCore

/// A settable clock the limiter reads through its `now` closure.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ start: TimeInterval) { value = start }

    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func advance(_ seconds: TimeInterval) { now += seconds }
}

@Suite("Rate limiter")
struct RateLimiterTests {
    func limiter(_ clock: TestClock, policy: RateLimiter.Policy = RateLimiter.Policy()) -> RateLimiter {
        RateLimiter(policy: policy, now: { clock.now })
    }

    @Test("calls: burst of 30, then 120/min, refill capped at the burst")
    func callBurst() {
        let clock = TestClock(2_000_000_000)
        let limiter = limiter(clock)
        for index in 0..<30 { #expect(limiter.allow("a", write: false) == .allowed, "burst \(index)") }
        #expect(limiter.allow("a", write: false) == .limited(retryAfter: 1), "31st call")
        // Limited calls don't consume tokens: hammering doesn't push the wait out.
        for _ in 0..<50 { _ = limiter.allow("a", write: false) }
        clock.advance(0.5)
        #expect(limiter.allow("a", write: false) == .allowed, "one token after 0.5 s")
        #expect(limiter.allow("a", write: false) == .limited(retryAfter: 1), "and only one")
        // Refill caps at the burst.
        clock.advance(3_600)
        for index in 0..<30 { #expect(limiter.allow("a", write: false) == .allowed, "refilled \(index)") }
        #expect(limiter.allow("a", write: false) == .limited(retryAfter: 1), "capped at 30")

        // Per-client isolation.
        for index in 0..<30 { #expect(limiter.allow("b", write: false) == .allowed, "client b \(index)") }
        #expect(limiter.allow("b", write: false) == .limited(retryAfter: 1), "client b limited")
        #expect(limiter.allow("c", write: true) == .allowed, "client c unaffected")
    }

    @Test("writes: burst 10, then 20/min, separate from calls")
    func writes() {
        let clock = TestClock(2_000_000_000)
        let limiter = limiter(clock)
        for index in 0..<10 { #expect(limiter.allow("w", write: true) == .allowed, "write \(index)") }
        #expect(limiter.allow("w", write: true) == .limited(retryAfter: 3), "11th write")
        clock.advance(1.5)
        #expect(limiter.allow("w", write: true) == .limited(retryAfter: 2), "write half refilled")
        // The limited writes took no call tokens: 30 - 10 = 20 reads remain
        // (plus 0.5 s × 2/s = 3 after 1.5 s, capped by the bucket).
        var reads = 0
        while limiter.allow("w", write: false) == .allowed { reads += 1 }
        #expect(reads == 23, "reads after limited writes")
        #expect(limiter.allow("w", write: true) == .limited(retryAfter: 1), "an empty call bucket blocks writes too")
        clock.advance(1.5)
        #expect(limiter.allow("w", write: true) == .allowed, "write after refill")
        // A client whose writes are exhausted still reads.
        let separate = self.limiter(clock)
        for _ in 0..<10 { _ = separate.allow("s", write: true) }
        #expect(separate.allow("s", write: true) == .limited(retryAfter: 3), "writes exhausted")
        #expect(separate.allow("s", write: false) == .allowed, "reads still allowed")
    }

    @Test("retry-after reflects the configured rate")
    func configuredRate() {
        let clock = TestClock(2_000_000_000)
        var slowPolicy = RateLimiter.Policy()
        slowPolicy.callsPerMinute = 6
        slowPolicy.callBurst = 2
        let slow = limiter(clock, policy: slowPolicy)
        #expect(slow.allow("x", write: false) == .allowed, "slow 1")
        #expect(slow.allow("x", write: false) == .allowed, "slow 2")
        #expect(slow.allow("x", write: false) == .limited(retryAfter: 10), "slow wait 10")
        clock.advance(5)
        #expect(slow.allow("x", write: false) == .limited(retryAfter: 5), "slow wait 5")
        clock.advance(5)
        #expect(slow.allow("x", write: false) == .allowed, "slow refilled")
    }

    @Test("250 dispatched writes per rolling 24 h")
    func dailyCap() {
        // One write every 3 s stays inside 20/min.
        let start: TimeInterval = 2_000_100_000
        let clock = TestClock(start)
        // The daily cap is charged only for writes that are dispatched
        // (recordWrite); refused or declined ones don't use it up.
        let daily = limiter(clock)
        for _ in 0..<300 {
            #expect(daily.allow("d", write: true) == .allowed, "undispatched writes don't count")
            clock.advance(3)
        }
        clock.now = start
        for index in 0..<250 {
            #expect(daily.allow("d", write: true) == .allowed, "daily write \(index)")
            daily.recordWrite("d")
            clock.advance(3)
        }
        #expect(daily.allow("d", write: true) == .limited(retryAfter: 86_400 - 750), "251st write")
        #expect(daily.allow("d", write: false) == .allowed, "reads unaffected by the daily cap")
        clock.now = start + 86_400 - 1
        #expect(daily.allow("d", write: true) == .limited(retryAfter: 1), "one second before rollover")
        clock.now = start + 86_400
        #expect(daily.allow("d", write: true) == .allowed, "first write left the window")
        daily.recordWrite("d")
        #expect(daily.allow("d", write: true) == .limited(retryAfter: 3), "250 in the window again")
        #expect(daily.allow("e", write: true) == .allowed, "other client's daily cap is separate")
    }

    @Test("failed authentication: more than 120 in a minute locks out for 60 s")
    func authLockout() {
        let clock = TestClock(2_000_300_000)
        let auth = limiter(clock)
        #expect(auth.authLockout() == nil)
        for _ in 0..<120 { auth.recordFailedAuth() }
        #expect(auth.authLockout() == nil, "120 is still allowed")
        auth.recordFailedAuth()
        #expect(auth.authLockout() == 60, "121st locks out")
        clock.advance(30)
        #expect(auth.authLockout() == 30)
        clock.advance(29.5)
        #expect(auth.authLockout() == 1)
        clock.advance(0.5)
        #expect(auth.authLockout() == nil, "recovered after 60 s")
        // The count restarts after a lockout, and old failures age out.
        for _ in 0..<120 { auth.recordFailedAuth() }
        clock.advance(60)
        for _ in 0..<120 { auth.recordFailedAuth() }
        #expect(auth.authLockout() == nil, "failures a minute apart don't add up")
        // Valid tokens never consult the lockout: per-client buckets are unaffected.
        for _ in 0..<121 { auth.recordFailedAuth() }
        #expect(auth.authLockout() == 60)
        #expect(auth.allow("valid", write: false) == .allowed, "authenticated call during lockout")
    }

    @Test("remote: stricter buckets, the shared daily cap, a lockout per forwarded address")
    func remote() {
        let clock = TestClock(2_000_500_000)
        let remote = limiter(clock)
        for index in 0..<15 {
            #expect(remote.allow("r", write: false, remote: true) == .allowed, "remote call \(index)")
        }
        #expect(remote.allow("r", write: false, remote: true) == .limited(retryAfter: 1), "16th remote call")
        #expect(remote.allow("r", write: false) == .allowed, "local bucket is separate")
        clock.advance(60)
        for index in 0..<5 {
            #expect(remote.allow("w", write: true, remote: true) == .allowed, "remote write \(index)")
        }
        #expect(remote.allow("w", write: true, remote: true) == .limited(retryAfter: 6), "6th remote write")
        for _ in 0..<250 { remote.recordWrite("d") }
        #expect(remote.allow("d", write: true, remote: true) == .limited(retryAfter: 86_400), "daily cap shared")
        for _ in 0..<30 { remote.recordFailedRemoteAuth("198.51.100.1") }
        #expect(remote.remoteAuthLockout("198.51.100.1") == nil, "30 a minute is allowed")
        remote.recordFailedRemoteAuth("198.51.100.1")
        #expect(remote.remoteAuthLockout("198.51.100.1") == 300, "31st locks that address out")
        #expect(remote.remoteAuthLockout("198.51.100.2") == nil, "other addresses unaffected")
        #expect(remote.authLockout() == nil, "the local lockout is separate")
        clock.advance(300)
        #expect(remote.remoteAuthLockout("198.51.100.1") == nil, "recovered after 5 min")
    }

    /// A flood of distinct addresses fills the table; new addresses then share one overflow key,
    /// which never locks out addresses already tracked.
    @Test func remoteOverflow() {
        let clock = TestClock(2_000_800_000)
        let flood = limiter(clock)
        flood.recordFailedRemoteAuth("203.0.113.7")
        for index in 0..<999 { flood.recordFailedRemoteAuth("10.0.\(index / 256).\(index % 256)") }
        for index in 0..<31 { flood.recordFailedRemoteAuth("192.0.2.\(index)") }
        #expect(flood.remoteAuthLockout("192.0.2.200") == 300, "untracked addresses share the overflow lockout")
        #expect(flood.remoteAuthLockout("203.0.113.7") == nil, "tracked addresses keep their own count")
        clock.advance(61)
        #expect(flood.remoteAuthLockout("192.0.2.200") == nil, "overflow applies only while the table is full")
    }
}
