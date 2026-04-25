@testable import NewsFeed
import Foundation
import Testing

@Suite("AuthFileLogger formatters")
struct AuthFileLoggerTests {
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    @Test func dayStringIsUTCYYYYMMDD() {
        let d = date("2026-04-25T18:32:14.000Z")
        #expect(AuthFileLogger.dayString(from: d) == "2026-04-25")
    }

    @Test func stampIsISO8601WithFractionalSeconds() {
        let d = date("2026-04-25T18:32:14.123Z")
        let stamp = AuthFileLogger.stampString(from: d)
        #expect(stamp.hasPrefix("2026-04-25T18:32:14"))
        #expect(stamp.hasSuffix("Z"))
    }
}
