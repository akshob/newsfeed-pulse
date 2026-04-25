import Fluent
import SQLKit

struct AddDupOfItemIdToItemScores: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("Expected SQLDatabase for ALTER TABLE migration")
        }
        try await sql.raw("""
            ALTER TABLE item_scores
              ADD COLUMN dup_of_item_id UUID NULL REFERENCES feed_items(id) ON DELETE SET NULL
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS item_scores_dup_of_item_idx
              ON item_scores (dup_of_item_id)
              WHERE dup_of_item_id IS NOT NULL
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS item_scores_dup_of_item_idx").run()
        try await sql.raw("ALTER TABLE item_scores DROP COLUMN IF EXISTS dup_of_item_id").run()
    }
}
