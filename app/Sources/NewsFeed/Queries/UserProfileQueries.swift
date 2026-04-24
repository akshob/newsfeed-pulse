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

/// Insert or update the user's `user_profiles` row: store the blurb and its
/// Ollama-generated embedding as a pgvector column.
func upsertUserProfile(userID: UUID, blurb: String, on req: Request) async throws {
    let ollama = OllamaClient(client: req.client)
    let embedding = try await ollama.embed(text: blurb)
    guard let sql = req.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }
    let existing = try await UserProfile.query(on: req.db)
        .filter(\.$user.$id == userID).first()
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
