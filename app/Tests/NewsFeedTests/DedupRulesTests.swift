@testable import NewsFeed
import Foundation
import Testing

@Suite("canonicalIDFromNeighbors")
struct DedupRulesTests {
    @Test func emptyNeighborsReturnsNil() {
        #expect(canonicalIDFromNeighbors([]) == nil)
    }

    @Test func nearestWithinThresholdReturnsItsID() {
        let canon = UUID()
        let result = canonicalIDFromNeighbors([(canon, 0.04)])
        #expect(result == canon)
    }

    @Test func nearestAtExactThresholdIsAccepted() {
        let canon = UUID()
        let result = canonicalIDFromNeighbors([(canon, DUP_DISTANCE_THRESHOLD)])
        #expect(result == canon)
    }

    @Test func nearestAboveThresholdReturnsNil() {
        let other = UUID()
        let result = canonicalIDFromNeighbors([(other, DUP_DISTANCE_THRESHOLD + 0.0001)])
        #expect(result == nil)
    }

    @Test func customThresholdIsHonored() {
        let canon = UUID()
        // Tighter threshold rejects a 0.07 match that the default would accept.
        #expect(canonicalIDFromNeighbors([(canon, 0.07)], threshold: 0.05) == nil)
        // Looser threshold accepts a 0.20 match the default would reject.
        #expect(canonicalIDFromNeighbors([(canon, 0.20)], threshold: 0.25) == canon)
    }

    @Test func onlyFirstNeighborMatters() {
        // Helper trusts the caller-provided ordering; nearest-first is a SQL
        // contract, not enforced here. Document that behavior with a test.
        let nearer = UUID()
        let farther = UUID()
        let result = canonicalIDFromNeighbors([(nearer, 0.30), (farther, 0.02)])
        #expect(result == nil) // first is out of threshold, even if a later entry would qualify
    }

    @Test func thresholdConstantsAreSane() {
        // Guardrails so an accidental edit doesn't silently make dedup absurd.
        #expect(DUP_DISTANCE_THRESHOLD > 0)
        #expect(DUP_DISTANCE_THRESHOLD < 0.5)
        #expect(DUP_RECENCY_HOURS >= 1)
        #expect(DUP_RECENCY_HOURS <= 24 * 14)
    }
}
