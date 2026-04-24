import Fluent

struct CreateInvites: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("invites")
            .id()
            .field("code", .string, .required)
            .field("created_by_user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("used_at", .datetime)
            .field("used_by_user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .unique(on: "code")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("invites").delete()
    }
}
