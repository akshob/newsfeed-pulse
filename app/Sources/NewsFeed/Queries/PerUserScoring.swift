import Fluent
import Foundation
import Logging
import SQLKit
import Vapor

/// Run an LLM rerank pass for a single user against THEIR current blurb.
/// Items already scored for this user with `scored_at >= profile.updatedAt`
/// are skipped (the existing per-user score is still fresh).
///
/// This is the same logic ScoreCommand's Phase 2 runs in cron — extracted
/// into a callable helper so OnboardingController can fire it from a Task
/// right after a user completes onboarding, without waiting for the next
/// cron tick.
///
/// Long-running. Hits the chat endpoint (oxygen by default) ~3-5s per item;
/// 200-item limit means ~10-15min worst case at 7B. Always call from a
/// detached Task so the request handler can return immediately.
@discardableResult
func rescoreUser(
    userID: UUID,
    application: Application,
    logger: Logger,
    fileLog: (@Sendable (String) async -> Void)? = nil,
    model overrideModel: String? = nil,
    limit: Int = 200,
    maxParallel: Int = 2
) async throws -> Int {
    guard let sql = application.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }
    let ollama = OllamaClient(client: application.client)
    let model = overrideModel
        ?? Environment.get("OLLAMA_CHAT_MODEL")
        ?? "qwen2.5:7b"

    struct UserRow: Decodable {
        let email: String
        let blurb: String
        let profile_updated_at: Date?
    }
    guard let user = try await sql.raw("""
        SELECT u.email AS email,
               p.blurb AS blurb,
               p.updated_at AS profile_updated_at
        FROM users u
        JOIN user_profiles p ON p.user_id = u.id
        WHERE u.id = \(bind: userID)
        LIMIT 1
        """).first(decoding: UserRow.self) else {
        logger.warning("rescoreUser: user \(userID) has no profile; skipping")
        return 0
    }

    // Order by the SAME ranking expression the feed query uses, so the items
    // we score first are the ones the user is actually about to see at the
    // top — not just the most-recently-fetched ones. Glitch fix: previous
    // ORDER BY fi.fetched_at DESC meant brand-new users got their freshest
    // 38 items scored, while the items their feed actually surfaced (older
    // but higher relevance × cosine match) stayed unpersonalized.
    let items: [ScoringItemRow] = try await sql.raw("""
        WITH user_emb AS (
          SELECT embedding FROM user_profiles WHERE user_id = \(bind: userID) LIMIT 1
        )
        SELECT fi.id AS id, fi.title AS title, fi.body AS body,
               fs.name AS source_name, fs.lane AS source_lane
        FROM feed_items fi
        JOIN feed_sources fs ON fi.source_id = fs.id
        JOIN item_scores isc ON isc.item_id = fi.id
        LEFT JOIN user_item_scores uis
          ON uis.item_id = fi.id AND uis.user_id = \(bind: userID)
        WHERE isc.dup_of_item_id IS NULL
          AND fi.fetched_at > NOW() - INTERVAL '7 days'
          AND (
            uis.id IS NULL
            OR (uis.scored_at IS NOT NULL
                AND \(bind: user.profile_updated_at) IS NOT NULL
                AND uis.scored_at < \(bind: user.profile_updated_at))
          )
        ORDER BY (
          COALESCE(uis.relevance_score, isc.relevance_score)::float
          * GREATEST(0, 1 - (isc.embedding <=> (SELECT embedding FROM user_emb)))
          * GREATEST(0.5, 1 - EXTRACT(EPOCH FROM NOW() - COALESCE(fi.published_at, fi.fetched_at))/604800)
        ) DESC NULLS LAST
        LIMIT \(bind: limit)
        """).all(decoding: ScoringItemRow.self)

    logger.info("rescoreUser: \(user.email) has \(items.count) items to rescore (maxParallel=\(maxParallel))")
    await fileLog?("rescoreUser: \(user.email) eligible=\(items.count)")

    let userBlurb = user.blurb
    let userEmail = user.email

    // Same chunked-TaskGroup pattern as catchupTopItemsForUser.
    var done = 0
    var i = 0
    while i < items.count {
        let chunkEnd = Swift.min(i + maxParallel, items.count)
        let chunkDone = try await withThrowingTaskGroup(of: Bool.self) { group -> Int in
            for j in i..<chunkEnd {
                let item = items[j]
                group.addTask {
                    do {
                        let bodyClean = item.body.map(stripTags) ?? ""
                        let rerank = await llmRerank(
                            ollama: ollama, model: model,
                            blurb: userBlurb, row: item, body: bodyClean
                        )
                        try await sql.raw("""
                            INSERT INTO user_item_scores
                              (id, user_id, item_id, relevance_score, tldr, why_this, lane, scored_at)
                            VALUES
                              (\(bind: UUID()),
                               \(bind: userID),
                               \(bind: item.id),
                               \(bind: rerank.relevanceScore),
                               \(bind: rerank.tldr),
                               \(bind: rerank.whyThis),
                               \(bind: rerank.lane ?? item.sourceLane),
                               NOW())
                            ON CONFLICT (user_id, item_id) DO UPDATE SET
                              relevance_score = EXCLUDED.relevance_score,
                              tldr = EXCLUDED.tldr,
                              why_this = EXCLUDED.why_this,
                              lane = EXCLUDED.lane,
                              scored_at = EXCLUDED.scored_at
                            """).run()
                        return true
                    } catch {
                        logger.error("rescoreUser: \(userEmail) item \(item.id) failed: \(error)")
                        return false
                    }
                }
            }
            var count = 0
            for try await ok in group { if ok { count += 1 } }
            return count
        }
        done += chunkDone
        i = chunkEnd
        if done % 10 == 0 || i >= items.count {
            logger.info("rescoreUser: \(userEmail) progress \(done)/\(items.count)")
        }
    }
    logger.info("rescoreUser: \(userEmail) done \(done)/\(items.count)")
    await fileLog?("rescoreUser: \(userEmail) done \(done)/\(items.count)")
    return done
}
