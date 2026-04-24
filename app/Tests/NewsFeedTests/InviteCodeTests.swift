@testable import NewsFeed
import Foundation
import Testing

@Suite("Invite code generation")
struct InviteCodeTests {
    @Test func codeHasThreeGroupsSeparatedByHyphens() {
        let code = generateInviteCode()
        let parts = code.components(separatedBy: "-")
        #expect(parts.count == 3)
    }

    @Test func eachGroupIsFourCharacters() {
        for _ in 0..<50 {
            let parts = generateInviteCode().components(separatedBy: "-")
            for part in parts {
                #expect(part.count == 4)
            }
        }
    }

    @Test func usesOnlySafeAlphabet() {
        // Avoid 0/1/o/l (ambiguous). Only a-z minus those, plus 2-9.
        let safe = Set("abcdefghijkmnpqrstuvwxyz23456789")
        for _ in 0..<50 {
            for ch in generateInviteCode() where ch != "-" {
                #expect(safe.contains(ch), "unexpected char '\(ch)' in invite code")
            }
        }
    }

    @Test func codesAreDistinctAcrossCalls() {
        // Birthday-paradox: 100 codes with 32^12 keyspace — collisions essentially impossible
        let codes = Set((0..<100).map { _ in generateInviteCode() })
        #expect(codes.count == 100)
    }
}
