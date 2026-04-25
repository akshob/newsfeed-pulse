@testable import NewsFeed
import Foundation
import Testing

@Suite("OnboardingFileLogger formatters")
struct OnboardingFileLoggerTests {
    @Test func dayStringIsUTCYYYYMMDD() {
        // 2026-04-25 11:32:14 PT == 2026-04-25 18:32:14 UTC — same day in UTC.
        let date = Date(timeIntervalSince1970: 1777748534)
        let day = OnboardingFileLogger.dayString(from: date)
        #expect(day == "2026-04-25")
    }

    @Test func dayStringRollsAtUTCMidnight() {
        // 2026-04-25 18:00:00 PT == 2026-04-26 01:00:00 UTC — UTC sees the next day.
        let date = Date(timeIntervalSince1970: 1777770000)
        #expect(OnboardingFileLogger.dayString(from: date) == "2026-04-26")
    }

    @Test func stampIsISO8601WithFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1777748534.123)
        let stamp = OnboardingFileLogger.stampString(from: date)
        #expect(stamp.hasPrefix("2026-04-25T18:32:14"))
        #expect(stamp.hasSuffix("Z"))
        // Fractional seconds present — at least one digit after the dot.
        #expect(stamp.contains(".1") || stamp.contains(".0"))
    }
}
