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
func loadRankedFeed(on req: Request, limit: Int, orderByScore: Bool = true) async throws -> [RankedRow] {
    guard let sql = req.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }
    let orderClause = orderByScore
        ? "ORDER BY isc.relevance_score DESC NULLS LAST, isc.similarity DESC NULLS LAST, fi.published_at DESC NULLS LAST"
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
