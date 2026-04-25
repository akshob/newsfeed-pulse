import Foundation
import Vapor

/// Row shape used by both global (Phase 1) and per-user (Phase 2) scoring.
/// Carries the minimum needed to compute an LLM rerank for an item.
struct ScoringItemRow: Decodable {
    let id: UUID
    let title: String
    let body: String?
    let source_name: String
    let source_lane: String

    var sourceName: String { source_name }
    var sourceLane: String { source_lane }
}

struct RerankResult {
    let relevanceScore: Int
    let tldr: String
    let whyThis: String
    let lane: String?
}

private struct RerankJSON: Codable {
    let relevance_score: Int?
    let tldr: String?
    let why_this: String?
    let lane: String?
}

/// LLM-driven rerank: scores a single item against a profile blurb and
/// returns a relevance score, tldr, why-this, and predicted lane. Used by:
/// - global Phase 1 (against the generic Data/interests.md blurb)
/// - per-user Phase 2 (against each user's user_profiles.blurb)
///
/// Falls back to a neutral score (5/10 + title-as-tldr) on any failure
/// so a single bad LLM call doesn't drop an item out of the feed.
func llmRerank(
    ollama: OllamaClient,
    model: String,
    blurb: String,
    row: ScoringItemRow,
    body: String
) async -> RerankResult {
    let system = "You are a news item evaluator. Output ONLY a JSON object with no prose."
    let userMsg = """
    USER INTEREST PROFILE:
    \(blurb)

    NEWS ITEM:
    Title: \(row.title)
    Source: \(row.sourceName) (lane: \(row.sourceLane))
    Body (excerpt): \(body.prefix(1500))

    Score this item for this specific user. Return ONLY a JSON object with these keys:
    - relevance_score: integer 1-10 (1=skip, 10=must-read for this user)
    - tldr: 1-2 sentence summary (max 220 chars, plain text, no markdown)
    - why_this: single short sentence explaining why it fits this user's interests
    - lane: "tech" or "conversation" — which of user's two interest lanes this serves

    JSON only, no markdown fences.
    """
    do {
        let raw = try await ollama.chat(
            model: model,
            system: system,
            user: userMsg,
            jsonMode: true,
            temperature: 0.2
        )
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = cleaned.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(RerankJSON.self, from: data) {
            let score = max(1, min(10, parsed.relevance_score ?? 5))
            let tldr = (parsed.tldr ?? row.title).trimmingCharacters(in: .whitespacesAndNewlines)
            let why  = (parsed.why_this ?? "relevant to your interests").trimmingCharacters(in: .whitespacesAndNewlines)
            let lane = parsed.lane.map { $0 == "tech" ? "tech" : "conversation" }
            return RerankResult(relevanceScore: score, tldr: tldr, whyThis: why, lane: lane)
        }
    } catch {
        // Fall through to fallback
    }
    return RerankResult(
        relevanceScore: 5,
        tldr: row.title,
        whyThis: "from \(row.sourceName)",
        lane: row.sourceLane
    )
}
