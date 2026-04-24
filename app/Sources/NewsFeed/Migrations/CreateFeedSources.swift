import Fluent

struct CreateFeedSources: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("feed_sources")
            .id()
            .field("name", .string, .required)
            .field("url", .string, .required)
            .field("lane", .string, .required)
            .field("active", .bool, .required, .sql(.default(true)))
            .field("created_at", .datetime)
            .unique(on: "url")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("feed_sources").delete()
    }
}
