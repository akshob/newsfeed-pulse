@testable import NewsFeed
import Foundation
import Testing

@Suite("composeUserEmbeddingText")
struct UserEmbeddingTextTests {
    @Test func blurbAloneReturnsBlurb() {
        let out = composeUserEmbeddingText(blurb: "I care about AI.", recentCaptures: [])
        #expect(out == "I care about AI.")
    }

    @Test func blurbIsTrimmed() {
        let out = composeUserEmbeddingText(blurb: "  hello  ", recentCaptures: [])
        #expect(out == "hello")
    }

    @Test func emptyBlurbAndCapturesYieldEmpty() {
        #expect(composeUserEmbeddingText(blurb: "", recentCaptures: []) == "")
        #expect(composeUserEmbeddingText(blurb: "   ", recentCaptures: []) == "")
    }

    @Test func capturesAppearInOrder() {
        let captures = [
            CaptureSummary(content: "first thing", sourceHint: nil),
            CaptureSummary(content: "second thing", sourceHint: nil),
        ]
        let out = composeUserEmbeddingText(blurb: "blurb", recentCaptures: captures)
        let firstIdx = out.range(of: "first thing")!.lowerBound
        let secondIdx = out.range(of: "second thing")!.lowerBound
        #expect(firstIdx < secondIdx)
    }

    @Test func sourceHintIsIncludedWhenPresent() {
        let captures = [CaptureSummary(content: "supreme court ruling", sourceHint: "wife")]
        let out = composeUserEmbeddingText(blurb: "blurb", recentCaptures: captures)
        #expect(out.contains("(wife)"))
        #expect(out.contains("supreme court ruling"))
    }

    @Test func sourceHintOmittedWhenNilOrEmpty() {
        let nilHint = composeUserEmbeddingText(
            blurb: "blurb",
            recentCaptures: [CaptureSummary(content: "thing", sourceHint: nil)]
        )
        let emptyHint = composeUserEmbeddingText(
            blurb: "blurb",
            recentCaptures: [CaptureSummary(content: "thing", sourceHint: "")]
        )
        #expect(!nilHint.contains("()"))
        #expect(!emptyHint.contains("()"))
    }

    @Test func blurbAndCapturesSeparated() {
        let captures = [CaptureSummary(content: "topic", sourceHint: nil)]
        let out = composeUserEmbeddingText(blurb: "I care about CS", recentCaptures: captures)
        #expect(out.contains("\n\n"))
        #expect(out.contains("Recently I've been hearing about:"))
    }

    @Test func capsAt20Captures() {
        let captures = (1...30).map { CaptureSummary(content: "capture \($0)", sourceHint: nil) }
        let out = composeUserEmbeddingText(blurb: "blurb", recentCaptures: captures)
        #expect(out.contains("capture 20"))
        #expect(!out.contains("capture 21"))
    }

    @Test func newlinesInCapturesAreFlattened() {
        let captures = [CaptureSummary(content: "line1\nline2\nline3", sourceHint: nil)]
        let out = composeUserEmbeddingText(blurb: "blurb", recentCaptures: captures)
        // The capture content shouldn't contribute extra blank list items
        #expect(out.contains("line1 line2 line3") || out.contains("line1  line2"))
    }
}
