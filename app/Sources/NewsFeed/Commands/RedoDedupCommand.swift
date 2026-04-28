import Fluent
import Foundation
import SQLKit
import Vapor

/// Re-evaluate `dup_of_item_id` for items in the recency window using the
/// current threshold. Run after bumping `DUP_DISTANCE_THRESHOLD` so older
/// items already in `item_scores` get the benefit of the new clustering
/// without waiting for ingest churn.
///
///     ./.build/release/NewsFeed redo-dedup [--hours N]
///
/// Process:
///   1. Clear `dup_of_item_id` for every item in the window (start fresh).
///   2. Iterate items oldest-fetched first. For each, find the nearest
///      cluster head (item with NULL `dup_of_item_id` already processed).
///      If within threshold, set this item's `dup_of_item_id` to it.
///      Otherwise this item becomes a head itself.
///
/// O(n²) but with the pgvector index each lookup is O(log n) so a 48h
/// window of ~150 items finishes in seconds.
struct RedoDedupCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "hours", help: "Look back N hours (default \(DUP_RECENCY_HOURS))")
        var hours: Int?
    }
    var help: String { "Recompute dup_of_item_id for recent items using current threshold" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let hours = signature.hours ?? DUP_RECENCY_HOURS
        context.console.print("redo-dedup: window=\(hours)h, threshold=\(DUP_DISTANCE_THRESHOLD)")

        let app = context.application
        guard let sql = app.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "expected SQLDatabase")
        }

        // 1. Clear every dup_of_item_id in the window so we can recompute
        //    cleanly. Items outside the window keep their existing state.
        try await sql.raw("""
            UPDATE item_scores
            SET dup_of_item_id = NULL
            WHERE item_id IN (
                SELECT id FROM feed_items
                WHERE fetched_at > NOW() - INTERVAL '\(unsafeRaw: String(hours)) hours'
            )
            """).run()

        // 2. Pull window items oldest-first so older ones become heads.
        struct ItemRow: Decodable { let item_id: UUID; let title: String }
        let items = try await sql.raw("""
            SELECT isc.item_id AS item_id, fi.title AS title
            FROM item_scores isc
            JOIN feed_items fi ON fi.id = isc.item_id
            WHERE fi.fetched_at > NOW() - INTERVAL '\(unsafeRaw: String(hours)) hours'
            ORDER BY fi.fetched_at ASC
            """).all(decoding: ItemRow.self)

        context.console.print("redo-dedup: scanning \(items.count) items")

        struct Neighbor: Decodable { let id: UUID; let distance: Double }
        var clusters = 0
        var heads = 0
        for item in items {
            // Find the nearest cluster head (NULL dup_of_item_id) within
            // the same window, excluding this item itself. Any item we've
            // already processed in this loop with no match becomes a head
            // and is eligible here.
            let recencyClause = "fi.fetched_at > NOW() - INTERVAL '\(hours) hours'"
            let neighbors = try await sql.raw("""
                SELECT fi.id AS id,
                       (isc.embedding <=> (
                          SELECT embedding FROM item_scores WHERE item_id = \(bind: item.item_id)
                       )) AS distance
                FROM item_scores isc
                JOIN feed_items fi ON fi.id = isc.item_id
                WHERE \(unsafeRaw: recencyClause)
                  AND isc.dup_of_item_id IS NULL
                  AND fi.id <> \(bind: item.item_id)
                ORDER BY isc.embedding <=> (
                  SELECT embedding FROM item_scores WHERE item_id = \(bind: item.item_id)
                ) ASC
                LIMIT 1
                """).all(decoding: Neighbor.self)

            let canon = canonicalIDFromNeighbors(neighbors.map { ($0.id, $0.distance) })
            if let canon = canon {
                try await sql.raw("""
                    UPDATE item_scores
                    SET dup_of_item_id = \(bind: canon)
                    WHERE item_id = \(bind: item.item_id)
                    """).run()
                clusters += 1
            } else {
                heads += 1
            }
        }

        context.console.print("redo-dedup done: \(heads) cluster heads, \(clusters) duplicates collapsed")
    }
}
