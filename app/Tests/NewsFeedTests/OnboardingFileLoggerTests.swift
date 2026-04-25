@testable import NewsFeed
import Foundation
import Testing

@Suite("OnboardingFileLogger formatters")
struct OnboardingFileLoggerTests {
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    @Test func dayStringIsUTCYYYYMMDD() {
        // 2026-04-25 18:32:14 UTC == same day in UTC.
        let d = date("2026-04-25T18:32:14.000Z")
        #expect(OnboardingFileLogger.dayString(from: d) == "2026-04-25")
    }

    @Test func dayStringRollsAtUTCMidnight() {
        // 2026-04-26 01:00:00 UTC — UTC sees the next calendar day.
        let d = date("2026-04-26T01:00:00.000Z")
        #expect(OnboardingFileLogger.dayString(from: d) == "2026-04-26")
    }

    @Test func stampIsISO8601WithFractionalSeconds() {
        let d = date("2026-04-25T18:32:14.123Z")
        let stamp = OnboardingFileLogger.stampString(from: d)
        #expect(stamp.hasPrefix("2026-04-25T18:32:14"))
        #expect(stamp.hasSuffix("Z"))
        // Fractional seconds present — at least one digit after the dot.
        #expect(stamp.contains(".1") || stamp.contains(".0"))
    }
}
