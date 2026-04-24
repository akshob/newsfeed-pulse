@testable import NewsFeed
import Foundation
import Testing

@Suite("Identicon")
struct IdenticonTests {
    @Test func isDeterministic() {
        let a = identiconSVG(for: "alice@example.com")
        let b = identiconSVG(for: "alice@example.com")
        #expect(a == b)
    }

    @Test func isCaseInsensitive() {
        let lower = identiconSVG(for: "alice@example.com")
        let upper = identiconSVG(for: "ALICE@EXAMPLE.COM")
        #expect(lower == upper)
    }

    @Test func differentSeedsProduceDifferentOutput() {
        let a = identiconSVG(for: "alice@example.com")
        let b = identiconSVG(for: "bob@example.com")
        #expect(a != b)
    }

    @Test func containsSVGWrapper() {
        let svg = identiconSVG(for: "x@y.z")
        #expect(svg.contains("<svg"))
        #expect(svg.contains("</svg>"))
    }

    @Test func respectsSize() {
        let svg = identiconSVG(for: "x@y.z", size: 64)
        #expect(svg.contains("width=\"64\""))
        #expect(svg.contains("height=\"64\""))
    }

    @Test func avatarHTMLEmptyForNil() {
        #expect(avatarHTML(for: nil) == "")
        #expect(avatarHTML(for: "") == "")
    }

    @Test func avatarHTMLWrapsSVGInLink() {
        let html = avatarHTML(for: "a@b.com")
        #expect(html.contains("href=\"/account\""))
        #expect(html.contains("<svg"))
        #expect(html.contains("class=\"avatar-link\""))
    }
}
