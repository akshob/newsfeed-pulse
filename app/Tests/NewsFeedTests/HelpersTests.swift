@testable import NewsFeed
import Foundation
import Testing

@Suite("HTML helpers")
struct HTMLHelpersTests {
    @Test func escapesAngleBrackets() {
        #expect(htmlEscape("<script>") == "&lt;script&gt;")
    }

    @Test func escapesAmpersandFirst() {
        // & must be escaped before < > so "&amp;" doesn't double-escape
        #expect(htmlEscape("A & B") == "A &amp; B")
        #expect(htmlEscape("<a>") == "&lt;a&gt;")
    }

    @Test func escapesQuotes() {
        #expect(htmlEscape("She said \"hi\"") == "She said &quot;hi&quot;")
        #expect(htmlEscape("It's") == "It&#39;s")
    }

    @Test func leavesPlainTextAlone() {
        #expect(htmlEscape("hello world") == "hello world")
        #expect(htmlEscape("") == "")
    }

    @Test func stripTagsRemovesTags() {
        #expect(stripTags("<p>hello</p>") == "hello")
        #expect(stripTags("<a href=\"x\">link</a>") == "link")
    }

    @Test func stripTagsDecodesEntities() {
        #expect(stripTags("Tom &amp; Jerry") == "Tom & Jerry")
        #expect(stripTags("&lt;note&gt;") == "<note>")
        #expect(stripTags("2&nbsp;pm") == "2 pm")
    }

    @Test func stripTagsTrimsOuterWhitespace() {
        #expect(stripTags("  <p>hello</p>  ") == "hello")
    }
}

@Suite("Relative time")
struct RelativeTimeTests {
    @Test func nilReturnsEmpty() {
        #expect(relativeTime(nil) == "")
    }

    @Test func justNowForRecent() {
        let now = Date()
        #expect(relativeTime(now) == "just now")
        #expect(relativeTime(now.addingTimeInterval(-30)) == "just now")
    }

    @Test func minutesBucket() {
        let fiveMinAgo = Date().addingTimeInterval(-300)
        #expect(relativeTime(fiveMinAgo) == "5m ago")
    }

    @Test func hoursBucket() {
        let twoHoursAgo = Date().addingTimeInterval(-2 * 3600)
        #expect(relativeTime(twoHoursAgo) == "2h ago")
    }

    @Test func daysBucket() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 86400)
        #expect(relativeTime(threeDaysAgo) == "3d ago")
    }

    @Test func monthsBucket() {
        let sixtyDaysAgo = Date().addingTimeInterval(-60 * 86400)
        #expect(relativeTime(sixtyDaysAgo) == "2mo ago")
    }
}
