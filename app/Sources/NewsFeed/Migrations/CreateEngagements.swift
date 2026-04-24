import Fluent
import SQLKit

struct CreateEngagements: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("engagements")
            .id()
            .field("item_id", .uuid, .required, .references("feed_items", "id", onDelete: .cascade))
            .field("event", .string, .required)
            .field("created_at", .datetime)
            .create()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX idx_engagements_item ON engagements(item_id)").run()
            try await sql.raw("CREATE INDEX idx_engagements_event_time ON engagements(event, created_at DESC)").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("engagements").delete()
    }
}
