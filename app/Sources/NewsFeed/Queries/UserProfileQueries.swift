import Fluent
import Foundation
import SQLKit
import Vapor

/// Named presets exposed as checkboxes on the onboarding form. Submitted
/// values are looked up here to produce readable text for the LLM embedding.
///
/// `science` and `health` are separate keys (formerly one combined bucket)
/// — the previous combination made it impossible to express "I want
/// climate science but skip health stuff", which the LLM parser exposed
/// as a real user pain point. Source tagging in feeds.json reflects the
/// split: NYT Health → ["health"], NYT Science → ["science"], etc.
let interestCategories: [(key: String, label: String, blurb: String)] = [
    ("tech",      "Tech, AI, CS",                                         "Tech, AI, and computer science"),
    ("politics",  "Politics & current events",                             "Politics and current events (help me catch up on context I'm missing)"),
    ("world",     "World news",                                            "World news"),
    ("culture",   "Culture, drama, what people are talking about",         "Culture, human drama, and what people are talking about"),
    ("business",  "Business & finance",                                    "Business and finance"),
    ("science",   "Science (research, climate, physics)",                  "Science — research, climate, biology, physics, basic discoveries"),
    ("health",    "Health & medicine",                                     "Health and medicine — public health, breakthroughs, drug news"),
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

/// Kept-items signal: titles of articles the user explicitly marked
/// `keep`. Blended into the embedding text so user_match drifts toward
/// the topics they engage with.
struct KeptSummary {
    let title: String
}

/// Combine the user's interest blurb with their recent captures and the
/// titles of items they've recently kept into a single text passed to the
/// embedder. Captures bias the user's vector toward what they've recently
/// mentioned hearing about ("I heard from wife"); kept items bias it
/// toward what they actually engaged with in-app.
func composeUserEmbeddingText(
    blurb: String,
    recentCaptures: [CaptureSummary],
    recentKept: [KeptSummary] = []
) -> String {
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
    if !recentKept.isEmpty {
        var section = "Items I've kept (positive signals — surface more like these):"
        for k in recentKept.prefix(20) {
            section += "\n- \(k.title.replacingOccurrences(of: "\n", with: " "))"
        }
        parts.append(section)
    }
    return parts.joined(separator: "\n\n")
}

/// Insert or update the user's `user_profiles` row.
///
/// - If `newBlurb` is supplied (onboarding form submit), the blurb is replaced.
///   Otherwise the existing blurb is preserved.
/// - If `newCategories` is supplied, the explicit category array is replaced.
///   Existing categories preserved otherwise.
/// - `newExcludedCategories` follows the same shape (LLM-parsed exclusions
///   from the freeform body; nil = preserve existing).
/// - The embedding is always recomputed from blurb + recent captures so the
///   user's vector drifts toward their recent "heard from..." inputs.
func upsertUserProfile(
    userID: UUID,
    newBlurb: String? = nil,
    newCategories: [String]? = nil,
    newInferredCategories: [String]? = nil,
    newExcludedCategories: [String]? = nil,
    on req: Request
) async throws {
    guard let sql = req.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }
    contextualLog(req, "upsertUserProfile: user=\(userID) hasNewBlurb=\(newBlurb != nil) cats=\(newCategories?.count ?? -1) inferred=\(newInferredCategories?.count ?? -1) excludes=\(newExcludedCategories?.count ?? -1)")

    let existing = try await UserProfile.query(on: req.db)
        .filter(\.$user.$id == userID).first()

    let blurb: String
    if let newBlurb = newBlurb {
        blurb = newBlurb
    } else if let existing = existing {
        blurb = existing.blurb
    } else {
        contextualLog(req, "upsertUserProfile: no blurb available for \(userID); skipping", level: .warning)
        return
    }

    let captures = try await Capture.query(on: req.db)
        .filter(\.$user.$id == userID)
        .sort(\.$capturedAt, .descending)
        .limit(20)
        .all()
        .map { CaptureSummary(content: $0.content, sourceHint: $0.sourceHint) }

    let kept = try await fetchRecentKeptForUser(userID: userID, on: req.db, limit: 20)

    let embedText = composeUserEmbeddingText(blurb: blurb, recentCaptures: captures, recentKept: kept)
    contextualLog(req, "upsertUserProfile: embedding text len=\(embedText.count) chars, captures=\(captures.count), kept=\(kept.count)")

    let ollama = OllamaClient(client: req.client)
    let embedStart = Date()
    let embedding: [Double]
    do {
        embedding = try await ollama.embed(text: embedText)
    } catch {
        contextualLog(req, "upsertUserProfile: ollama.embed failed after \(Int(Date().timeIntervalSince(embedStart)*1000))ms: \(String(reflecting: error))", level: .error)
        throw error
    }
    contextualLog(req, "upsertUserProfile: embedded in \(Int(Date().timeIntervalSince(embedStart)*1000))ms, dim=\(embedding.count)")

    // Build TEXT[] literals for any provided new categories. Pass-through nil
    // means "don't touch existing column" — the SET clause then omits those.
    func arrayLiteral(_ values: [String]) -> String {
        let escaped = values.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        return "ARRAY[\(escaped)]::TEXT[]"
    }
    var categoryAssign = ""
    if let newCategories = newCategories {
        categoryAssign = ", categories = \(arrayLiteral(newCategories))"
    }
    var inferredAssign = ""
    if let newInferred = newInferredCategories {
        inferredAssign = ", inferred_categories = \(arrayLiteral(newInferred))"
    }
    var excludesAssign = ""
    if let newExcluded = newExcludedCategories {
        excludesAssign = ", excluded_categories = \(arrayLiteral(newExcluded))"
    }

    if let existing = existing, let existingID = existing.id {
        try await sql.raw("""
            UPDATE user_profiles
            SET blurb = \(bind: blurb),
                embedding = \(unsafeRaw: "'\(pgvectorLiteral(embedding))'::vector"),
                updated_at = NOW()
                \(unsafeRaw: categoryAssign)
                \(unsafeRaw: inferredAssign)
                \(unsafeRaw: excludesAssign)
            WHERE id = \(bind: existingID)
            """).run()
        contextualLog(req, "upsertUserProfile: updated existing profile \(existingID)")
    } else {
        // INSERT path: brand-new profile row. Always include all three arrays
        // (default to empty rather than omit so the NOT NULL DEFAULT '{}'
        // takes effect predictably).
        let insertCats = newCategories ?? []
        let insertInferred = newInferredCategories ?? []
        let insertExcludes = newExcludedCategories ?? []
        try await sql.raw("""
            INSERT INTO user_profiles (id, user_id, blurb, embedding, categories, inferred_categories, excluded_categories, updated_at)
            VALUES (\(bind: UUID()),
                    \(bind: userID),
                    \(bind: blurb),
                    \(unsafeRaw: "'\(pgvectorLiteral(embedding))'::vector"),
                    \(unsafeRaw: arrayLiteral(insertCats)),
                    \(unsafeRaw: arrayLiteral(insertInferred)),
                    \(unsafeRaw: arrayLiteral(insertExcludes)),
                    NOW())
            """).run()
        contextualLog(req, "upsertUserProfile: inserted new profile for \(userID)")
    }
}

/// Fetch the titles of items this user has marked `keep` recently. Used as
/// a positive-signal contribution to the embedding text so cosine similarity
/// drifts toward what the user actually engages with.
func fetchRecentKeptForUser(
    userID: UUID,
    on db: any Database,
    limit: Int = 20
) async throws -> [KeptSummary] {
    guard let sql = db as? any SQLDatabase else { return [] }
    struct Row: Decodable { let title: String }
    let rows = try await sql.raw("""
        SELECT fi.title AS title
        FROM engagements e
        JOIN feed_items fi ON fi.id = e.item_id
        WHERE e.user_id = \(bind: userID)
          AND e.event = 'keep'
          AND e.created_at > NOW() - INTERVAL '30 days'
        ORDER BY e.created_at DESC
        LIMIT \(bind: limit)
        """).all(decoding: Row.self)
    return rows.map { KeptSummary(title: $0.title) }
}

/// Application-context (no Request) version of the embedding refresh used
/// by `upsertUserProfile`. Called from background Tasks (e.g.
/// EngageController fires this after a `keep` event) where the
/// originating Request has already returned.
///
/// Reads blurb + recent captures + recent keeps, composes the embedding
/// text, calls the embedder, and writes the new vector back. Bumps
/// updated_at so user_item_scores get rescored on the next score run
/// (the LLM-derived relevance text becomes stale once the embedding
/// drifts).
func evolveUserEmbedding(
    userID: UUID,
    application: Application,
    logger: Logger
) async throws {
    guard let sql = application.db as? any SQLDatabase else {
        logger.warning("evolveUserEmbedding: no SQL database for \(userID)")
        return
    }

    struct ProfileRow: Decodable { let blurb: String }
    guard let p = try await sql.raw("""
        SELECT blurb FROM user_profiles WHERE user_id = \(bind: userID) LIMIT 1
        """).first(decoding: ProfileRow.self) else {
        logger.warning("evolveUserEmbedding: no profile for \(userID); skipping")
        return
    }

    struct CaptureRow: Decodable {
        let content: String
        let source_hint: String?
    }
    let captureRows = try await sql.raw("""
        SELECT content, source_hint FROM captures
        WHERE user_id = \(bind: userID)
        ORDER BY captured_at DESC
        LIMIT 20
        """).all(decoding: CaptureRow.self)
    let captures = captureRows.map {
        CaptureSummary(content: $0.content, sourceHint: $0.source_hint)
    }

    let kept = try await fetchRecentKeptForUser(userID: userID, on: application.db, limit: 20)

    let embedText = composeUserEmbeddingText(blurb: p.blurb, recentCaptures: captures, recentKept: kept)
    let ollama = OllamaClient(client: application.client)
    let started = Date()
    let embedding: [Double]
    do {
        embedding = try await ollama.embed(text: embedText)
    } catch {
        logger.error("evolveUserEmbedding: embed failed for \(userID): \(error)")
        throw error
    }
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)

    try await sql.raw("""
        UPDATE user_profiles
        SET embedding = \(unsafeRaw: "'\(pgvectorLiteral(embedding))'::vector"),
            updated_at = NOW()
        WHERE user_id = \(bind: userID)
        """).run()

    logger.info("evolveUserEmbedding: \(userID) embedded in \(elapsed)ms (captures=\(captures.count) kept=\(kept.count))")
}

/// Strip the structured "Interested in: ..." prefix line from a stored blurb
/// so the textarea on /onboarding shows only what the user actually typed.
/// Convention: composeBlurb produces "Interested in: ...\n\n<freeform>" when
/// categories are non-empty.
func freeformPart(of blurb: String) -> String {
    let chunks = blurb.components(separatedBy: "\n\n")
    return chunks
        .filter { !$0.hasPrefix("Interested in:") }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
