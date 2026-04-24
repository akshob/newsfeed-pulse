import Fluent
import SQLKit

/// Also adds `similarity_at_vote` — captured at vote time so we can later
/// analyze skip patterns vs. embedding similarity.
struct AddUserIdToEngagements: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Wipe any pre-auth rows — they can't be attributed to a user.
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DELETE FROM engagements").run()
        }
        try await database.schema("engagements")
            .field("user_id", .uuid, .references("users", "id", onDelete: .cascade))
            .field("similarity_at_vote", .float)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("engagements")
            .deleteField("user_id")
            .deleteField("similarity_at_vote")
            .update()
    }
}
