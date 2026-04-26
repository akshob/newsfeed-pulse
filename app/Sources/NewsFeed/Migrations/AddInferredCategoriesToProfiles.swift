import Fluent
import SQLKit

/// Adds `inferred_categories TEXT[]` to user_profiles so the LLM-extracted
/// signals from freeform stay separate from `categories` (the user's
/// explicit checkbox picks). Lets the form render the two cleanly:
/// checkboxes = explicit selection only, "inferred from your description"
/// tag row = whatever the LLM picked up from the freeform body.
///
/// Filter logic (in FeedQueries) takes the union for inclusion. Excluded
/// categories continue to live in their own column.
struct AddInferredCategoriesToProfiles: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("Expected SQLDatabase for ALTER migration")
        }
        try await sql.raw("""
            ALTER TABLE user_profiles
              ADD COLUMN inferred_categories TEXT[] NOT NULL DEFAULT '{}'
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            ALTER TABLE user_profiles DROP COLUMN IF EXISTS inferred_categories
            """).run()
    }
}
