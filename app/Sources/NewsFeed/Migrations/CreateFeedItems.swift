import Fluent

struct CreateFeedItems: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("feed_items")
            .id()
            .field("source_id", .uuid, .required, .references("feed_sources", "id", onDelete: .cascade))
            .field("external_id", .string, .required)
            .field("url", .string, .required)
            .field("title", .string, .required)
            .field("body", .string)
            .field("published_at", .datetime)
            .field("fetched_at", .datetime)
            .unique(on: "source_id", "external_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("feed_items").delete()
    }
}
