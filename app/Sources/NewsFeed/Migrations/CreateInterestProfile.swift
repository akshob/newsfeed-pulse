import Fluent
import SQLKit

struct CreateInterestProfile: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("Expected SQLDatabase for raw pgvector migration")
        }
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS vector").run()
        try await sql.raw("""
            CREATE TABLE interest_profile (
                id UUID PRIMARY KEY,
                blurb TEXT NOT NULL,
                embedding vector(768),
                version INT NOT NULL DEFAULT 1,
                updated_at TIMESTAMP
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS interest_profile").run()
    }
}
