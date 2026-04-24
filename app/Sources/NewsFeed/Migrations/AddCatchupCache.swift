import Fluent
import SQLKit

struct AddCatchupCache: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("Expected SQLDatabase for ALTER TABLE migration")
        }
        try await sql.raw("""
            ALTER TABLE item_scores
              ADD COLUMN catchup_html TEXT,
              ADD COLUMN catchup_generated_at TIMESTAMP
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            ALTER TABLE item_scores
              DROP COLUMN IF EXISTS catchup_html,
              DROP COLUMN IF EXISTS catchup_generated_at
            """).run()
    }
}
