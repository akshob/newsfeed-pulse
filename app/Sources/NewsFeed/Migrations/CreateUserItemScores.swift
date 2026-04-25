import Fluent
import SQLKit

struct CreateUserItemScores: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_item_scores")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("item_id", .uuid, .required, .references("feed_items", "id", onDelete: .cascade))
            .field("relevance_score", .int)
            .field("tldr", .string)
            .field("why_this", .string)
            .field("lane", .string)
            .field("scored_at", .datetime)
            .unique(on: "user_id", "item_id")
            .create()

        // Per-item lookups (e.g. "all users' takes on this item") are rare today
        // but the index is cheap and keeps that query path open.
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS user_item_scores_item_idx
              ON user_item_scores(item_id)
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_item_scores").delete()
    }
}
