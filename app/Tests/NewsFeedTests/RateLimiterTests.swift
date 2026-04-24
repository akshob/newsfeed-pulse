@testable import NewsFeed
import Foundation
import Testing

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test func allowsUpToLimitThenBlocks() async {
        let limiter = RateLimiter(maxEvents: 3, window: 60)
        #expect(await limiter.allow(key: "1.2.3.4"))
        #expect(await limiter.allow(key: "1.2.3.4"))
        #expect(await limiter.allow(key: "1.2.3.4"))
        #expect(await limiter.allow(key: "1.2.3.4") == false)
    }

    @Test func keysAreIndependent() async {
        let limiter = RateLimiter(maxEvents: 2, window: 60)
        #expect(await limiter.allow(key: "a"))
        #expect(await limiter.allow(key: "a"))
        #expect(await limiter.allow(key: "b"))     // b's counter is independent
        #expect(await limiter.allow(key: "a") == false)
        #expect(await limiter.allow(key: "b"))     // b still under limit
    }

    @Test func windowDiscardsOldEvents() async {
        let limiter = RateLimiter(maxEvents: 2, window: 10)
        let now = Date()

        // Pre-seed two events outside the window
        await limiter.record(key: "x", at: now.addingTimeInterval(-100))
        await limiter.record(key: "x", at: now.addingTimeInterval(-50))

        // Should allow because old events are outside the 10s window
        #expect(await limiter.allow(key: "x", now: now))
        #expect(await limiter.allow(key: "x", now: now))
        #expect(await limiter.allow(key: "x", now: now) == false)
    }

    @Test func zeroEventsBlocksImmediately() async {
        let limiter = RateLimiter(maxEvents: 0, window: 60)
        #expect(await limiter.allow(key: "x") == false)
    }

    @Test func blockingDoesNotAddNewEvent() async {
        // If allow() returns false, we shouldn't keep appending events —
        // otherwise a steady stream of blocked requests would extend the
        // window of bans indefinitely.
        let limiter = RateLimiter(maxEvents: 1, window: 60)
        #expect(await limiter.allow(key: "x"))
        // These should all be blocked
        for _ in 0..<5 {
            #expect(await limiter.allow(key: "x") == false)
        }
        // After the window passes (simulated via record at far past), allow again
        let future = Date().addingTimeInterval(120)
        #expect(await limiter.allow(key: "x", now: future))
    }
}
