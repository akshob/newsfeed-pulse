import Fluent
import Foundation
import SQLKit
import Vapor

/// Generate the catchup explainer for a single feed_item by id, on demand.
/// Useful when you want to backfill one specific article without running
/// the full catchup-all batch.
///
///     ./.build/release/NewsFeed catchup <item-id>
///
/// Skips if catchup_html is already set unless --force is passed.
struct CatchupCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "item_id", help: "feed_items.id (UUID) to generate the explainer for")
        var itemID: String
        @Option(name: "model", help: "Chat model name; falls back to OLLAMA_CHAT_MODEL env, else llama3.2:3b")
        var model: String?
        @Flag(name: "force", help: "Regenerate even if catchup_html is already set")
        var force: Bool
    }
    var help: String { "Generate catchup HTML for a single item by id" }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let itemID = UUID(uuidString: signature.itemID) else {
            context.console.error("✗ not a UUID: \(signature.itemID)")
            return
        }
        let app = context.application
        guard let sql = app.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "expected SQLDatabase")
        }
        let ollama = OllamaClient(client: app.client)
        let model = signature.model
            ?? Environment.get("OLLAMA_CHAT_MODEL")
            ?? "llama3.2:3b"

        struct Row: Decodable {
            let title: String
            let body: String?
            let source_name: String
            let has_existing: Bool
        }
        guard let row = try await sql.raw("""
            SELECT fi.title AS title, fi.body AS body, fs.name AS source_name,
                   (isc.catchup_html IS NOT NULL) AS has_existing
            FROM feed_items fi
            JOIN feed_sources fs ON fi.source_id = fs.id
            LEFT JOIN item_scores isc ON isc.item_id = fi.id
            WHERE fi.id = \(bind: itemID)
            LIMIT 1
            """).first(decoding: Row.self) else {
            context.console.error("✗ no feed_item with id: \(itemID)")
            return
        }

        if row.has_existing && !signature.force {
            context.console.print("(already has catchup_html — pass --force to regenerate)")
            return
        }

        context.console.print("catchup: \(row.title.prefix(80))…")
        let html = try await buildExplainer(
            ollama: ollama, model: model,
            title: row.title, source: row.source_name, body: row.body
        )

        // item_scores might not exist yet (e.g. unscored item) — UPSERT to handle either path.
        try await sql.raw("""
            INSERT INTO item_scores (id, item_id, catchup_html, catchup_generated_at, scored_at)
            VALUES (\(bind: UUID()), \(bind: itemID), \(bind: html), NOW(), NOW())
            ON CONFLICT (item_id) DO UPDATE SET
              catchup_html = EXCLUDED.catchup_html,
              catchup_generated_at = EXCLUDED.catchup_generated_at
            """).run()
        context.console.print("✓ wrote \(html.count) chars of HTML")
    }
}
