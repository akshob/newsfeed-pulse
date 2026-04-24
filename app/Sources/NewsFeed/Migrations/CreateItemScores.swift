import Fluent
import SQLKit

struct CreateItemScores: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("Expected SQLDatabase for raw pgvector migration")
        }
        try await sql.raw("""
            CREATE TABLE item_scores (
                id UUID PRIMARY KEY,
                item_id UUID NOT NULL UNIQUE REFERENCES feed_items(id) ON DELETE CASCADE,
                embedding vector(768),
                similarity REAL,
                relevance_score INTEGER,
                tldr TEXT,
                why_this TEXT,
                lane TEXT,
                scored_at TIMESTAMP
            )
            """).run()
        try await sql.raw("""
            CREATE INDEX idx_item_scores_relevance
              ON item_scores (relevance_score DESC NULLS LAST, scored_at DESC NULLS LAST)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS item_scores").run()
    }
}
