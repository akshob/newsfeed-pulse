import Fluent
import SQLKit

struct CreateUserProfiles: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("Expected SQLDatabase for pgvector migration")
        }
        try await sql.raw("""
            CREATE TABLE user_profiles (
                id UUID PRIMARY KEY,
                user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
                blurb TEXT NOT NULL,
                embedding vector(768),
                updated_at TIMESTAMP
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS user_profiles").run()
    }
}
