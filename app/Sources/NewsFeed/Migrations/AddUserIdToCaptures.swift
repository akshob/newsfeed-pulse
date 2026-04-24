import Fluent
import SQLKit

struct AddUserIdToCaptures: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Wipe any pre-auth rows — they can't be attributed to a user.
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DELETE FROM captures").run()
        }
        try await database.schema("captures")
            .field("user_id", .uuid, .references("users", "id", onDelete: .cascade))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("captures")
            .deleteField("user_id")
            .update()
    }
}
