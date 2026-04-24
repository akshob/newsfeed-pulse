@testable import NewsFeed
import Foundation
import Testing

@Suite("Cosine similarity")
struct CosineSimilarityTests {
    @Test func identicalVectorsAreOne() {
        let v: [Double] = [1, 2, 3, 4]
        let similarity = cosineSimilarity(v, v)
        #expect(abs(similarity - 1.0) < 1e-10)
    }

    @Test func orthogonalVectorsAreZero() {
        #expect(abs(cosineSimilarity([1, 0], [0, 1])) < 1e-10)
    }

    @Test func oppositeVectorsAreNegativeOne() {
        let sim = cosineSimilarity([1, 2], [-1, -2])
        #expect(abs(sim - (-1.0)) < 1e-10)
    }

    @Test func emptyInputReturnsZero() {
        #expect(cosineSimilarity([], []) == 0)
    }

    @Test func mismatchedLengthReturnsZero() {
        #expect(cosineSimilarity([1, 2], [1]) == 0)
    }

    @Test func zeroVectorReturnsZero() {
        // Avoid division by zero; similarity with a zero-magnitude vector is 0
        #expect(cosineSimilarity([0, 0, 0], [1, 2, 3]) == 0)
    }

    @Test func known45DegreeAngle() {
        // cos(45°) = √2/2 ≈ 0.7071
        let sim = cosineSimilarity([1, 0], [1, 1])
        #expect(abs(sim - 0.7071) < 0.0001)
    }
}

@Suite("pgvector literal + parse roundtrip")
struct PGVectorTests {
    @Test func literalStartsWithBracket() {
        let s = pgvectorLiteral([0.1, 0.2])
        #expect(s.hasPrefix("["))
        #expect(s.hasSuffix("]"))
    }

    @Test func literalUsesEightDecimals() {
        let s = pgvectorLiteral([0.5])
        #expect(s == "[0.50000000]")
    }

    @Test func literalSeparatesWithCommas() {
        let s = pgvectorLiteral([1, 2, 3])
        #expect(s.components(separatedBy: ",").count == 3)
    }

    @Test func roundtripPreservesValues() {
        let original: [Double] = [0.1, -0.5, 2.75, 1e-6, -3.14159265]
        let literal = pgvectorLiteral(original)
        let parsed = parsePGVector(literal)
        #expect(parsed != nil)
        #expect(parsed!.count == original.count)
        for (a, b) in zip(parsed!, original) {
            #expect(abs(a - b) < 1e-7)
        }
    }

    @Test func parseHandlesWhitespace() {
        let parsed = parsePGVector("[ 1.0 , 2.0 , 3.0 ]")
        #expect(parsed == [1.0, 2.0, 3.0])
    }

    @Test func parseReturnsNilForMalformedInput() {
        #expect(parsePGVector("") == nil)
        #expect(parsePGVector("[]") == nil)
        #expect(parsePGVector("[abc,def]") == nil)
    }
}
