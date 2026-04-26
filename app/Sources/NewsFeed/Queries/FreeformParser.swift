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
    "tech", "politics", "world", "culture", "business", "science", "health", "sports"
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
      tech       — software, AI, LLMs, dev tooling, computer science, programming
      politics   — elections, policy, partisan stories, government
      world      — geopolitics, international news, wars, foreign affairs
      culture    — drama, celebrities, public figures, social moments, entertainment
      business   — markets, stocks, deals, company news, economy, finance
      science    — research, climate, physics, biology, basic discoveries (NOT health)
      health     — medicine, drug news, public health, hospitals, healthcare policy
      sports     — only when crossing into cultural-event territory

    User's free-text description:
    \"\"\"
    \(trimmed)
    \"\"\"

    For each of the 8 categories decide:
    - INCLUDE: user mentions a topic, field, technology, or example that \
      maps to this category. Be reasonably generous — listing a topic is \
      itself a signal of interest.
    - EXCLUDE: user uses negative language ("no", "skip", "avoid", "not \
      interested in", "boring", "hate") about this category.
    - NEITHER: category isn't mentioned at all.

    Important — science and health are SEPARATE keys:
      "climate science", "physics", "biology research" → science
      "medical breakthroughs", "drug approvals", "Botox", "public health" → health
      "no health" alone → exclude health (NOT science)
      "skip medical" → exclude health (NOT science)

    Worked examples:
      "AI/LLM research, climate science, no health, no politics"
        → {"include": ["tech", "science"], "exclude": ["health", "politics"]}
      "want stocks and election coverage; skip celebrity drama"
        → {"include": ["business", "politics"], "exclude": ["culture"]}
      "geopolitics and wars please, nothing about sports"
        → {"include": ["world"], "exclude": ["sports"]}
      "medical breakthroughs and Supreme Court news"
        → {"include": ["health", "politics"], "exclude": []}

    Use ONLY the 8 keys above. Don't invent new keys.

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
