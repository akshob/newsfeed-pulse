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
    }

    var help: String { "Pre-generate catchup explainers for items missing cached HTML" }

    func run(using context: CommandContext, signature: Signature) async throws {
        context.console.print("catchup-all: starting")
        let app = context.application
        let limit = signature.limit ?? 200
        let ollama = OllamaClient(client: app.client)

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
                let html = try await buildExplainer(ollama: ollama, title: p.title, source: p.source_name, body: p.body)
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

    private func buildExplainer(
        ollama: OllamaClient,
        title: String,
        source: String,
        body: String?
    ) async throws -> String {
        let cleanBody = (body.map(stripTagsForBuild) ?? "").prefix(2000)

        let system = """
        You are a neutral news explainer for someone smart who hasn't been following the story. \
        Present both sides' strongest case fairly. Never opine. Output clean HTML only, no markdown.
        """

        let user = """
        Item title: \(title)
        Source: \(source)
        Body: \(cleanBody)

        Write a catch-me-up explainer using ONLY these HTML tags: <h2>, <p>, <ul>, <li>, <strong>.
        Do not wrap in <html>, <body>, or <article>.

        Structure:
        <h2>Background</h2>
        <p>2-3 sentences of historical context. Who/what are the key players? When did this start?</p>

        <h2>What's new</h2>
        <p>1-2 sentences on what just happened that made this newsworthy now.</p>

        <h2>The two strongest takes</h2>
        <ul>
          <li><strong>One side says:</strong> steelman their case in 1-2 sentences</li>
          <li><strong>The other side says:</strong> steelman their case in 1-2 sentences</li>
        </ul>

        <h2>Conversation starter</h2>
        <p>One specific angle or question you could raise.</p>

        Rules:
        - If this is clearly a factual item with no controversy (weather, obituary, tech release), skip the "two strongest takes" section entirely.
        - Do not add any commentary outside the structure.
        """

        return try await ollama.chat(
            model: "llama3.2:3b",
            system: system,
            user: user,
            jsonMode: false,
            temperature: 0.3,
            numCtx: 4096
        )
    }
}

private func stripTagsForBuild(_ s: String) -> String {
    let noTags = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    return noTags
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
