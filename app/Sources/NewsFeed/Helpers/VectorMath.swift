import Foundation

/// Cosine similarity between two equal-length vectors.
/// Returns 0 for empty or mismatched-length inputs.
func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, magA = 0.0, magB = 0.0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        magA += a[i] * a[i]
        magB += b[i] * b[i]
    }
    let denom = magA.squareRoot() * magB.squareRoot()
    return denom == 0 ? 0 : dot / denom
}

/// Format a Swift [Double] as pgvector's text representation: "[0.1,0.2,...]"
func pgvectorLiteral(_ v: [Double]) -> String {
    "[" + v.map { String(format: "%.8f", $0) }.joined(separator: ",") + "]"
}

/// Parse pgvector's text representation back into [Double].
/// Returns nil on malformed input.
func parsePGVector(_ text: String) -> [Double]? {
    let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n\t"))
    guard !stripped.isEmpty else { return nil }
    let parts = stripped.split(separator: ",")
    let doubles = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    return doubles.count == parts.count ? doubles : nil
}
