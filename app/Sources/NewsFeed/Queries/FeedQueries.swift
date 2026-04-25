import Fluent
import Foundation
import SQLKit
import Vapor

/// Row shape returned by the ranked-feed SQL query.
struct RankedRow: Decodable {
    let id: UUID
    let title: String
    let url: String
    let body: String?
    let published_at: Date?
    let fetched_at: Date?
    let source_name: String
    let source_lane: String
    let relevance_score: Int?
    let similarity: Float?
    let tldr: String?
    let why_this: String?
    let predicted_lane: String?
    let latest_engagement: String?
}

/// Load the top-N ranked feed items, personalized to the given user.
///
/// Ranking score = `relevance_score × user_match × recency_decay`, where:
///   - `relevance_score`: 1-10 from the LLM rerank (global, item quality)
///   - `user_match`: `max(0, 1 − cosine_distance(item.embedding, user.embedding))`
///     — pgvector `<=>` distance, scoped to *this* user's blurb embedding
///   - `recency_decay`: `max(0.5, 1 − age_days/7)` — fresh items beat stale
///
/// Skip filter is also user-scoped: only items *this* user has marked 'skip'
/// drop out (other users' skips don't hide them).
///
/// Falls through gracefully when the user has no profile (rare — controllers
/// redirect to /onboarding first): NULL embedding → all scores collapse to 0
/// → tiebreaker becomes published_at.
func loadRankedFeed(
    on req: Request,
    userID: UUID,
    limit: Int,
    orderByScore: Bool = true
) async throws -> [RankedRow] {
    guard let sql = req.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }

    // Per-user fields fall back to the global item_scores values when this
    // user hasn't been scored on the item yet (e.g. brand-new user, or item
    // arrived after the last per-user pass). Once Phase 2 of ScoreCommand
    // runs for them, the COALESCE picks up the personalized values.
    let scoreExpr = """
        COALESCE(
          COALESCE(uis.relevance_score, isc.relevance_score)::float
          * GREATEST(0, 1 - (isc.embedding <=> (SELECT embedding FROM user_emb)))
          * GREATEST(0.5, 1 - EXTRACT(EPOCH FROM NOW() - COALESCE(fi.published_at, fi.fetched_at)) / 604800),
          0
        )
        """
    let orderClause = orderByScore
        ? "ORDER BY \(scoreExpr) DESC NULLS LAST, fi.published_at DESC NULLS LAST"
        : "ORDER BY fi.published_at DESC NULLS LAST, fi.fetched_at DESC"

    return try await sql.raw("""
        WITH user_emb AS (
          SELECT embedding FROM user_profiles WHERE user_id = \(bind: userID) LIMIT 1
        )
        SELECT fi.id AS id,
               fi.title AS title,
               fi.url AS url,
               fi.body AS body,
               fi.published_at AS published_at,
               fi.fetched_at AS fetched_at,
               fs.name AS source_name,
               fs.lane AS source_lane,
               COALESCE(uis.relevance_score, isc.relevance_score) AS relevance_score,
               isc.similarity AS similarity,
               COALESCE(uis.tldr, isc.tldr) AS tldr,
               COALESCE(uis.why_this, isc.why_this) AS why_this,
               COALESCE(uis.lane, isc.lane) AS predicted_lane,
               (SELECT event FROM engagements eng
                  WHERE eng.item_id = fi.id AND eng.user_id = \(bind: userID)
                  ORDER BY eng.created_at DESC LIMIT 1) AS latest_engagement
        FROM feed_items fi
        JOIN feed_sources fs ON fi.source_id = fs.id
        LEFT JOIN item_scores isc ON isc.item_id = fi.id
        LEFT JOIN user_item_scores uis
          ON uis.item_id = fi.id AND uis.user_id = \(bind: userID)
        WHERE isc.dup_of_item_id IS NULL
          AND (
            SELECT event FROM engagements eng2
              WHERE eng2.item_id = fi.id AND eng2.user_id = \(bind: userID)
              ORDER BY eng2.created_at DESC LIMIT 1
          ) IS DISTINCT FROM 'skip'
        \(unsafeRaw: orderClause)
        LIMIT \(bind: limit)
        """).all(decoding: RankedRow.self)
}

/// MAX(fetched_at) across all feed_items — used to show "last ingest Xh ago"
/// in the feed header. Returns nil on empty DB.
func loadLastIngestAt(on req: Request) async throws -> Date? {
    guard let sql = req.db as? any SQLDatabase else { return nil }
    struct Row: Decodable { let max_at: Date? }
    let row = try await sql.raw("SELECT MAX(fetched_at) AS max_at FROM feed_items")
        .first(decoding: Row.self)
    return row?.max_at
}
