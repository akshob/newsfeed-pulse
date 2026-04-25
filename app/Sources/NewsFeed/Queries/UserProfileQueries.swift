import Fluent
import Foundation
import SQLKit
import Vapor

/// Named presets exposed as checkboxes on the onboarding form. Submitted
/// values are looked up here to produce readable text for the LLM embedding.
let interestCategories: [(key: String, label: String, blurb: String)] = [
    ("tech",      "Tech, AI, CS",                                         "Tech, AI, and computer science"),
    ("politics",  "Politics & current events",                             "Politics and current events (help me catch up on context I'm missing)"),
    ("world",     "World news",                                            "World news"),
    ("culture",   "Culture, drama, what people are talking about",         "Culture, human drama, and what people are talking about"),
    ("business",  "Business & finance",                                    "Business and finance"),
    ("science",   "Science & health",                                      "Science and health"),
    ("sports",    "Sports (cultural moments only)",                        "Sports (only when it crosses into cultural-event territory)"),
]

/// Turn onboarding form input (categories + free-form text) into a single
/// blurb suitable for embedding.
func composeBlurb(categories: [String], freeform: String) -> String {
    let names: [String: String] = Dictionary(uniqueKeysWithValues: interestCategories.map { ($0.key, $0.blurb) })
    let selected = categories.compactMap { names[$0] }
    var parts: [String] = []
    if !selected.isEmpty {
        parts.append("Interested in: " + selected.joined(separator: "; ") + ".")
    }
    let trimmed = freeform.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { parts.append(trimmed) }
    return parts.joined(separator: "\n\n")
}

/// Lightweight value type used by `composeUserEmbeddingText` so tests can
/// exercise the formatting without depending on Fluent.
struct CaptureSummary {
    let content: String
    let sourceHint: String?
}

/// Combine the user's interest blurb with their recent captures into a single
/// text passed to the embedder. Captures bias the user's vector toward what
/// they've recently mentioned hearing about — closing the "I heard from wife"
/// loop into ranking.
func composeUserEmbeddingText(blurb: String, recentCaptures: [CaptureSummary]) -> String {
    var parts: [String] = []
    let trimmedBlurb = blurb.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedBlurb.isEmpty { parts.append(trimmedBlurb) }
    if !recentCaptures.isEmpty {
        var section = "Recently I've been hearing about:"
        for c in recentCaptures.prefix(20) {
            let line = c.content.replacingOccurrences(of: "\n", with: " ")
            if let hint = c.sourceHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                section += "\n- (\(hint)) \(line)"
            } else {
                section += "\n- \(line)"
            }
        }
        parts.append(section)
    }
    return parts.joined(separator: "\n\n")
}

/// Insert or update the user's `user_profiles` row.
///
/// - If `newBlurb` is supplied (onboarding form submit), the blurb is replaced.
///   Otherwise the existing blurb is preserved.
/// - The embedding is always recomputed from blurb + recent captures so the
///   user's vector drifts toward their recent "heard from..." inputs.
func upsertUserProfile(userID: UUID, newBlurb: String? = nil, on req: Request) async throws {
    guard let sql = req.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }

    let existing = try await UserProfile.query(on: req.db)
        .filter(\.$user.$id == userID).first()

    let blurb: String
    if let newBlurb = newBlurb {
        blurb = newBlurb
    } else if let existing = existing {
        blurb = existing.blurb
    } else {
        // No newBlurb provided AND no existing profile — nothing meaningful
        // to embed. Skip silently (the capture row is still saved).
        return
    }

    let captures = try await Capture.query(on: req.db)
        .filter(\.$user.$id == userID)
        .sort(\.$capturedAt, .descending)
        .limit(20)
        .all()
        .map { CaptureSummary(content: $0.content, sourceHint: $0.sourceHint) }

    let embedText = composeUserEmbeddingText(blurb: blurb, recentCaptures: captures)
    let ollama = OllamaClient(client: req.client)
    let embedding = try await ollama.embed(text: embedText)

    if let existing = existing, let existingID = existing.id {
        try await sql.raw("""
            UPDATE user_profiles
            SET blurb = \(bind: blurb),
                embedding = \(unsafeRaw: "'\(pgvectorLiteral(embedding))'::vector"),
                updated_at = NOW()
            WHERE id = \(bind: existingID)
            """).run()
    } else {
        try await sql.raw("""
            INSERT INTO user_profiles (id, user_id, blurb, embedding, updated_at)
            VALUES (\(bind: UUID()),
                    \(bind: userID),
                    \(bind: blurb),
                    \(unsafeRaw: "'\(pgvectorLiteral(embedding))'::vector"),
                    NOW())
            """).run()
    }
}
