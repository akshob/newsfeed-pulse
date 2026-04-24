import Fluent

struct CreateCaptures: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("captures")
            .id()
            .field("content", .string, .required)
            .field("source_hint", .string)
            .field("captured_at", .datetime)
            .field("processed_at", .datetime)
            .field("extracted_topics", .string)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("captures").delete()
    }
}
