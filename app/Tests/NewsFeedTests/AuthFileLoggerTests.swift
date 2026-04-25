@testable import NewsFeed
import Foundation
import Testing

@Suite("AuthFileLogger formatters")
struct AuthFileLoggerTests {
    @Test func dayStringIsUTCYYYYMMDD() {
        let date = Date(timeIntervalSince1970: 1777748534)  // 2026-04-25 18:32:14Z
        #expect(AuthFileLogger.dayString(from: date) == "2026-04-25")
    }

    @Test func stampIsISO8601WithFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1777748534.123)
        let stamp = AuthFileLogger.stampString(from: date)
        #expect(stamp.hasPrefix("2026-04-25T18:32:14"))
        #expect(stamp.hasSuffix("Z"))
    }
}
