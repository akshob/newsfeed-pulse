import Fluent
import Foundation
import Logging
import SQLKit
import Vapor

/// Generate `catchup_html` for the top-N items this user is about to see
/// in their feed. Cheap to call (returns 0 fast when nothing's pending),
/// expensive when there IS pending work (~10-30s per item × N items).
///
/// Always call from a Task.detached. Catchup_html is stored on the global
/// item_scores row (it doesn't depend on the user — the explainer for a
/// given article is the same regardless of who reads it), but the *which
/// items* selection here is per-user, using the same ranking expression
/// the feed view uses, so we prioritize whatever this user is most likely
/// to click first.
///
/// Fired from:
/// - OnboardingController.onboardingSubmit, after rescoreUser completes
/// - AuthController.loginSubmit, on every successful login (idempotent;
///   bail early if everything's already cached)
@discardableResult
func catchupTopItemsForUser(
    userID: UUID,
    application: Application,
    logger: Logger,
    limit: Int = 10,
    maxParallel: Int = 2,
    model overrideModel: String? = nil
) async throws -> Int {
    guard let sql = application.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }
    let ollama = OllamaClient(client: application.client)
    let model = overrideModel
        ?? Environment.get("OLLAMA_CHAT_MODEL")
        ?? "qwen2.5:7b"

    struct Pending: Decodable {
        let item_id: UUID
        let title: String
        let body: String?
        let source_name: String
    }

    // Same ranking expression as loadRankedFeed: per-user score when present
    // (uis.*), global fallback otherwise (isc.*), multiplied by user_match
    // and recency_decay. Filter to items missing an explainer.
    let pending = try await sql.raw("""
        WITH user_emb AS (
          SELECT embedding FROM user_profiles WHERE user_id = \(bind: userID) LIMIT 1
        )
        SELECT fi.id AS item_id, fi.title AS title, fi.body AS body, fs.name AS source_name
        FROM feed_items fi
        JOIN feed_sources fs ON fi.source_id = fs.id
        JOIN item_scores isc ON isc.item_id = fi.id
        LEFT JOIN user_item_scores uis
          ON uis.item_id = fi.id AND uis.user_id = \(bind: userID)
        WHERE isc.dup_of_item_id IS NULL
          AND isc.catchup_html IS NULL
          AND fi.fetched_at > NOW() - INTERVAL '7 days'
        ORDER BY (
          COALESCE(uis.relevance_score, isc.relevance_score)::float
          * GREATEST(0, 1 - (isc.embedding <=> (SELECT embedding FROM user_emb)))
          * GREATEST(0.5, 1 - EXTRACT(EPOCH FROM NOW() - COALESCE(fi.published_at, fi.fetched_at))/604800)
        ) DESC NULLS LAST
        LIMIT \(bind: limit)
        """).all(decoding: Pending.self)

    if pending.isEmpty {
        logger.info("catchupTopItemsForUser: \(userID) — nothing pending")
        return 0
    }
    logger.info("catchupTopItemsForUser: \(userID) — \(pending.count) explainers to generate (maxParallel=\(maxParallel))")

    // Process in chunks of `maxParallel`. Each chunk fires a TaskGroup so the
    // chat calls run in parallel client-side; oxygen's OLLAMA_NUM_PARALLEL
    // controls how many GPU-batches in parallel server-side. Both layers
    // need to match for actual throughput gain.
    var done = 0
    var i = 0
    while i < pending.count {
        let chunkEnd = Swift.min(i + maxParallel, pending.count)
        let chunkDone = try await withThrowingTaskGroup(of: Bool.self) { group -> Int in
            for j in i..<chunkEnd {
                let p = pending[j]
                group.addTask {
                    let started = Date()
                    do {
                        let html = try await buildExplainer(
                            ollama: ollama, model: model,
                            title: p.title, source: p.source_name, body: p.body
                        )
                        try await sql.raw("""
                            UPDATE item_scores
                            SET catchup_html = \(bind: html), catchup_generated_at = NOW()
                            WHERE item_id = \(bind: p.item_id)
                            """).run()
                        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                        logger.info("catchupTopItemsForUser: \(userID) ok (\(elapsed)ms) [\(p.title.prefix(60))]")
                        return true
                    } catch {
                        logger.error("catchupTopItemsForUser: \(userID) item \(p.item_id) failed: \(error)")
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
        logger.info("catchupTopItemsForUser: \(userID) progress \(done)/\(pending.count)")
    }
    return done
}
