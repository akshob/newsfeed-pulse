import Foundation
import Vapor

/// Calls the chat LLM (oxygen) to read a user's freeform interest text and
/// extract two arrays: `include` (categories the user wants) and `exclude`
/// (categories they explicitly don't want). Returns subsets of the 7 known
/// category keys.
///
/// On any failure (timeout, malformed JSON, oxygen down) returns empty
/// arrays — caller treats that as "no preferences extracted" and falls back
/// to whatever default they like.
struct FreeformParseResult {
    let include: [String]
    let exclude: [String]
}

private struct FreeformParseJSON: Codable {
    let include: [String]?
    let exclude: [String]?
}

private let knownCategoryKeys: Set<String> = [
    "tech", "politics", "world", "culture", "business", "science", "sports"
]

/// Parse the user's freeform interest text into structured category lists.
/// Conservative: if a category isn't mentioned, it's not added to either
/// include or exclude.
func parseFreeformInterests(
    text: String,
    ollama: OllamaClient,
    model: String
) async -> FreeformParseResult {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return FreeformParseResult(include: [], exclude: [])
    }

    let system = """
    You map a user's free-text news-interest description to two arrays of \
    category keys. Output ONLY a JSON object — no prose, no markdown fences.
    """

    let user = """
    Available category keys (use these exact strings):
      tech       — software, AI, dev tooling, computer science
      politics   — elections, policy, partisan stories
      world      — geopolitics, international news outside the user's country
      culture    — drama, public figures, social moments, entertainment
      business   — markets, deals, company news, finance
      science    — research, health, medicine, climate
      sports     — only when crossing into cultural-event territory

    User's free-text description:
    \"\"\"
    \(trimmed)
    \"\"\"

    Rules:
    - "include" is categories they explicitly say they want. If they only \
      mention something neutrally, do NOT include.
    - "exclude" is categories they say they DON'T want — words like "no", \
      "skip", "not interested", "avoid".
    - If a category isn't mentioned at all, it appears in NEITHER list.
    - Don't invent keys; only use the 7 listed above.

    Return ONLY: {"include": ["..."], "exclude": ["..."]}
    """

    do {
        let raw = try await ollama.chat(
            model: model,
            system: system,
            user: user,
            jsonMode: true,
            temperature: 0.1
        )
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(FreeformParseJSON.self, from: data) else {
            return FreeformParseResult(include: [], exclude: [])
        }
        // Sanitize against typos / hallucinated keys: keep only known categories.
        let include = (parsed.include ?? []).filter { knownCategoryKeys.contains($0) }
        let exclude = (parsed.exclude ?? []).filter { knownCategoryKeys.contains($0) }
        return FreeformParseResult(include: include, exclude: exclude)
    } catch {
        return FreeformParseResult(include: [], exclude: [])
    }
}
