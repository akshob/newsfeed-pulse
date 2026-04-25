import Fluent
import Foundation
import SQLKit
import Vapor

// Pre-generate catchup explainers for items that have a score but no cached catchup_html.
// Meant to run in the background (hourly cron or one-off backfill) so that clicks in the
// feed UI are instant instead of waiting ~40s for a cold LLM pass.
struct CatchupAllCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "limit", help: "Max items to process this run")
        var limit: Int?
        @Option(name: "model", help: "Chat model name; falls back to OLLAMA_CHAT_MODEL env, else llama3.2:3b")
        var model: String?
    }

    var help: String { "Pre-generate catchup explainers for items missing cached HTML" }

    func run(using context: CommandContext, signature: Signature) async throws {
        context.console.print("catchup-all: starting")
        let app = context.application
        let limit = signature.limit ?? 200
        let model = signature.model
            ?? Environment.get("OLLAMA_CHAT_MODEL")
            ?? "llama3.2:3b"
        let ollama = OllamaClient(client: app.client)
        context.console.print("catchup-all: using chat model \(model)")

        guard let sql = app.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "expected SQLDatabase")
        }

        struct Pending: Decodable {
            let item_id: UUID
            let title: String
            let body: String?
            let source_name: String
        }

        let pending = try await sql.raw("""
            SELECT isc.item_id AS item_id,
                   fi.title AS title,
                   fi.body AS body,
                   fs.name AS source_name
            FROM item_scores isc
            JOIN feed_items fi ON isc.item_id = fi.id
            JOIN feed_sources fs ON fi.source_id = fs.id
            WHERE isc.catchup_html IS NULL
            ORDER BY isc.relevance_score DESC NULLS LAST, fi.published_at DESC NULLS LAST
            LIMIT \(bind: limit)
            """).all(decoding: Pending.self)

        context.console.print("catchup-all: \(pending.count) items need explainers")

        var done = 0
        for p in pending {
            do {
                let html = try await buildExplainer(ollama: ollama, model: model, title: p.title, source: p.source_name, body: p.body)
                try await sql.raw("""
                    UPDATE item_scores
                    SET catchup_html = \(bind: html), catchup_generated_at = NOW()
                    WHERE item_id = \(bind: p.item_id)
                    """).run()
                done += 1
                if done % 5 == 0 {
                    context.console.print("  \(done)/\(pending.count)")
                }
            } catch {
                context.console.error("  [\(p.title.prefix(60))] \(error)")
            }
        }
        context.console.print("catchup-all done: \(done)/\(pending.count)")
    }

}

// NOTE: stripTags lives in Helpers/HTMLHelpers.swift; buildExplainer is shared
// across CatchupAllCommand, CatchupCommand, and catchupTopItemsForUser via
// Helpers/CatchupExplainer.swift.
