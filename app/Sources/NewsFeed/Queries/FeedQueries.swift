import Fluent
import Foundation
import SQLKit
import Vapor

/// Row shape returned by the ranked-feed SQL query. Used by FeedView to render
/// each card and by tests.
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

/// Load the top-N ranked feed items. Phase 1: ranking is global (no user-scoped
/// similarity yet); skip filter is also global (any user's skip hides an item
/// from everyone). Phase 2 will scope both to the current user via
/// `user_profiles.embedding` and per-user engagements.
///
/// Ranking applies a gentle recency decay so a 9-rated item from a week ago
/// loses to an 8-rated item from today. Multiplier =
/// `GREATEST(0.5, 1 − age_days / 7)` — full weight at 0 days, hits the
/// 0.5 floor by ~7 days. Falls through to similarity, then publish date.
func loadRankedFeed(on req: Request, limit: Int, orderByScore: Bool = true) async throws -> [RankedRow] {
    guard let sql = req.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }
    let decayedScore = """
        (isc.relevance_score::float
         * GREATEST(0.5, 1 - EXTRACT(EPOCH FROM NOW() - COALESCE(fi.published_at, fi.fetched_at)) / 604800))
        """
    let orderClause = orderByScore
        ? "ORDER BY \(decayedScore) DESC NULLS LAST, isc.similarity DESC NULLS LAST, fi.published_at DESC NULLS LAST"
        : "ORDER BY fi.published_at DESC NULLS LAST, fi.fetched_at DESC"
    let skipFilter = """
        (SELECT event FROM engagements eng2
           WHERE eng2.item_id = fi.id
           ORDER BY eng2.created_at DESC LIMIT 1) IS DISTINCT FROM 'skip'
        """
    return try await sql.raw("""
        SELECT fi.id AS id,
               fi.title AS title,
               fi.url AS url,
               fi.body AS body,
               fi.published_at AS published_at,
               fi.fetched_at AS fetched_at,
               fs.name AS source_name,
               fs.lane AS source_lane,
               isc.relevance_score AS relevance_score,
               isc.similarity AS similarity,
               isc.tldr AS tldr,
               isc.why_this AS why_this,
               isc.lane AS predicted_lane,
               (SELECT event FROM engagements eng
                  WHERE eng.item_id = fi.id
                  ORDER BY eng.created_at DESC LIMIT 1) AS latest_engagement
        FROM feed_items fi
        JOIN feed_sources fs ON fi.source_id = fs.id
        LEFT JOIN item_scores isc ON isc.item_id = fi.id
        WHERE \(unsafeRaw: skipFilter)
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
