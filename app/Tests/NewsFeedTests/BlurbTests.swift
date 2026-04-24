@testable import NewsFeed
import Foundation
import Testing

@Suite("composeBlurb")
struct ComposeBlurbTests {
    @Test func emptyInputsProduceEmptyString() {
        #expect(composeBlurb(categories: [], freeform: "") == "")
        #expect(composeBlurb(categories: [], freeform: "   \n  ") == "")
    }

    @Test func freeformOnlyReturnsTrimmedFreeform() {
        #expect(composeBlurb(categories: [], freeform: "  hello  ") == "hello")
    }

    @Test func categoriesOnlyProducesInterestList() {
        let result = composeBlurb(categories: ["tech"], freeform: "")
        #expect(result.hasPrefix("Interested in: "))
        #expect(result.contains("Tech, AI"))
        #expect(result.hasSuffix("."))
    }

    @Test func multipleCategoriesJoinedWithSemicolons() {
        let result = composeBlurb(categories: ["tech", "politics"], freeform: "")
        #expect(result.contains("; "))
    }

    @Test func bothInputsSeparatedByBlankLine() {
        let result = composeBlurb(categories: ["tech"], freeform: "skip PR noise")
        // Categories, then double-newline, then freeform
        #expect(result.contains("\n\n"))
        #expect(result.contains("Interested in:"))
        #expect(result.contains("skip PR noise"))
    }

    @Test func unknownCategoryIsIgnored() {
        // Arbitrary category keys that aren't in the preset list are dropped
        let result = composeBlurb(categories: ["not-a-real-category"], freeform: "")
        #expect(result == "")
    }

    @Test func categoryOrderIsPreserved() {
        let result = composeBlurb(categories: ["tech", "world"], freeform: "")
        let techIdx = result.range(of: "Tech, AI")!.lowerBound
        let worldIdx = result.range(of: "World news")!.lowerBound
        #expect(techIdx < worldIdx)
    }
}

@Suite("interestCategories catalog")
struct InterestCategoriesTests {
    @Test func allCategoriesHaveUniqueKeys() {
        let keys = interestCategories.map { $0.key }
        #expect(keys.count == Set(keys).count)
    }

    @Test func allCategoriesHaveNonEmptyFields() {
        for cat in interestCategories {
            #expect(!cat.key.isEmpty)
            #expect(!cat.label.isEmpty)
            #expect(!cat.blurb.isEmpty)
        }
    }

    @Test func keysAreLowercaseAndURLSafe() {
        // Keys are used as form values + class names; must not need escaping
        for cat in interestCategories {
            #expect(cat.key == cat.key.lowercased())
            #expect(cat.key.range(of: "[^a-z0-9_-]", options: .regularExpression) == nil)
        }
    }
}
