import Fluent
import SQLKit

/// Replaces blurb-substring-matching as the source of truth for "which
/// categories did this user pick" with explicit TEXT[] columns on
/// user_profiles. Same shape on feed_sources so a source can be tagged
/// with multiple categories (Quanta = science+tech, NPR = world+politics+
/// culture+science, etc.) instead of the old single `lane` field.
///
/// Existing rows get a one-time backfill from their current blurb's
/// "Interested in: ..." structured prefix line — only the structured part,
/// never the freeform — so the false-positive checkbox bug doesn't
/// reproduce during migration.
struct AddCategoriesToProfiles: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("Expected SQLDatabase for ALTER + UPDATE migration")
        }

        // 1. user_profiles: explicit categories + LLM-parsed exclusions.
        try await sql.raw("""
            ALTER TABLE user_profiles
              ADD COLUMN categories          TEXT[] NOT NULL DEFAULT '{}',
              ADD COLUMN excluded_categories TEXT[] NOT NULL DEFAULT '{}'
            """).run()

        // 2. feed_sources: multi-tag. Keep `lane` for now (UI styling reads it)
        //    but introduce `categories` as the filtering source of truth.
        try await sql.raw("""
            ALTER TABLE feed_sources
              ADD COLUMN categories TEXT[] NOT NULL DEFAULT '{}'
            """).run()

        // 3. Backfill user_profiles.categories by parsing the structured
        //    "Interested in: <blurb1>; <blurb2>." prefix line — never the
        //    freeform body, since that's where the substring-match bug lived.
        //    For each known category key, check if its blurb appears in the
        //    first line of the saved blurb (the line that starts with
        //    "Interested in:").
        let categoryKeys: [(key: String, blurb: String)] = [
            ("tech",     "Tech, AI, and computer science"),
            ("politics", "Politics and current events"),
            ("world",    "World news"),
            ("culture",  "Culture, human drama, and what people are talking about"),
            ("business", "Business and finance"),
            ("science",  "Science and health"),
            ("sports",   "Sports (only when it crosses into cultural-event territory)"),
        ]
        for (key, blurb) in categoryKeys {
            try await sql.raw("""
                UPDATE user_profiles
                SET categories = array_append(categories, \(bind: key))
                WHERE
                  -- Look only at the first \\n\\n-separated chunk and only when
                  -- it starts with the structured prefix.
                  split_part(blurb, E'\\n\\n', 1) LIKE 'Interested in:%'
                  AND POSITION(\(bind: blurb) IN split_part(blurb, E'\\n\\n', 1)) > 0
                  AND NOT (\(bind: key) = ANY(categories))
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            ALTER TABLE user_profiles
              DROP COLUMN IF EXISTS categories,
              DROP COLUMN IF EXISTS excluded_categories
            """).run()
        try await sql.raw("""
            ALTER TABLE feed_sources
              DROP COLUMN IF EXISTS categories
            """).run()
    }
}
