import Fluent
import Foundation
import SQLKit
import Vapor

struct ScoreCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "limit", short: "n", help: "Max items to score this run (default 100)")
        var limit: Int?
        @Option(name: "model", help: "Chat model for rerank (default llama3.2:3b)")
        var model: String?
    }

    var help: String {
        "Score feed_items: compute embeddings, cosine similarity, LLM rerank+TLDR, store in item_scores"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        context.console.print("score: starting")
        let app = context.application
        let limit = signature.limit ?? 100
        let model = signature.model ?? "llama3.2:3b"
        let ollama = OllamaClient(client: app.client)

        guard let sql = app.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "expected SQLDatabase")
        }
        context.console.print("score: sql ready")

        // 1. Ensure interest profile embedding exists and matches current blurb
        let profileEmbedding: [Double]
        do {
            profileEmbedding = try await ensureProfileEmbedding(app: app, ollama: ollama, sql: sql)
        } catch {
            context.console.error("score: profile embed failed: \(error)")
            throw error
        }
        context.console.print("profile embedding ready (dim=\(profileEmbedding.count))")

        // 2. Find un-scored items
        context.console.print("score: querying un-scored items")
        let rows: [UnScoredRow]
        do {
            rows = try await sql.raw("""
                SELECT fi.id AS id, fi.title AS title, fi.body AS body, fs.name AS source_name, fs.lane AS source_lane
                FROM feed_items fi
                JOIN feed_sources fs ON fi.source_id = fs.id
                LEFT JOIN item_scores isc ON isc.item_id = fi.id
                WHERE isc.id IS NULL
                ORDER BY fi.fetched_at DESC
                LIMIT \(bind: limit)
                """).all(decoding: UnScoredRow.self)
        } catch {
            context.console.error("score: un-scored query failed: \(error)")
            throw error
        }

        context.console.print("scoring \(rows.count) items…")

        let blurb = try loadBlurb(app: app)
        var scored = 0
        for row in rows {
            do {
                try await scoreOne(row: row,
                                   blurb: blurb,
                                   profileEmbedding: profileEmbedding,
                                   ollama: ollama,
                                   model: model,
                                   sql: sql)
                scored += 1
                if scored % 10 == 0 {
                    context.console.print("  scored \(scored)/\(rows.count)")
                }
            } catch {
                context.console.error("  [\(row.title.prefix(60))] error: \(error)")
            }
        }
        context.console.print("Done: \(scored)/\(rows.count) scored")
    }

    // MARK: - Single item

    private func scoreOne(
        row: UnScoredRow,
        blurb: String,
        profileEmbedding: [Double],
        ollama: OllamaClient,
        model: String,
        sql: any SQLDatabase
    ) async throws {
        // Build text to embed — title is highest signal, body adds context
        let bodyClean = row.body.map(stripTags) ?? ""
        let embedText = "\(row.title)\n\n\(bodyClean.prefix(800))"

        let itemEmbedding = try await ollama.embed(text: embedText)
        let similarity = cosineSimilarity(profileEmbedding, itemEmbedding)

        // LLM rerank + TLDR + why_this + lane
        let rerank = await llmRerank(
            ollama: ollama,
            model: model,
            blurb: blurb,
            row: row,
            body: bodyClean
        )

        try await sql.raw("""
            INSERT INTO item_scores
              (id, item_id, embedding, similarity, relevance_score, tldr, why_this, lane, scored_at)
            VALUES
              (\(bind: UUID()),
               \(bind: row.id),
               \(unsafeRaw: "'\(pgvectorLiteral(itemEmbedding))'::vector"),
               \(bind: Float(similarity)),
               \(bind: rerank.relevanceScore),
               \(bind: rerank.tldr),
               \(bind: rerank.whyThis),
               \(bind: rerank.lane ?? row.sourceLane),
               NOW())
            """).run()
    }

    // MARK: - LLM rerank

    private struct RerankResult {
        let relevanceScore: Int
        let tldr: String
        let whyThis: String
        let lane: String?
    }

    private struct RerankJSON: Codable {
        let relevance_score: Int?
        let tldr: String?
        let why_this: String?
        let lane: String?
    }

    private func llmRerank(
        ollama: OllamaClient,
        model: String,
        blurb: String,
        row: UnScoredRow,
        body: String
    ) async -> RerankResult {
        let system = "You are a news item evaluator. Output ONLY a JSON object with no prose."
        let userMsg = """
        USER INTEREST PROFILE:
        \(blurb)

        NEWS ITEM:
        Title: \(row.title)
        Source: \(row.sourceName) (lane: \(row.sourceLane))
        Body (excerpt): \(body.prefix(1500))

        Score this item for this specific user. Return ONLY a JSON object with these keys:
        - relevance_score: integer 1-10 (1=skip, 10=must-read for this user)
        - tldr: 1-2 sentence summary (max 220 chars, plain text, no markdown)
        - why_this: single short sentence explaining why it fits this user's interests
        - lane: "tech" or "conversation" — which of user's two interest lanes this serves

        JSON only, no markdown fences.
        """
        do {
            let raw = try await ollama.chat(
                model: model,
                system: system,
                user: userMsg,
                jsonMode: true,
                temperature: 0.2
            )
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = cleaned.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(RerankJSON.self, from: data) {
                let score = max(1, min(10, parsed.relevance_score ?? 5))
                let tldr = (parsed.tldr ?? row.title).trimmingCharacters(in: .whitespacesAndNewlines)
                let why  = (parsed.why_this ?? "relevant to your interests").trimmingCharacters(in: .whitespacesAndNewlines)
                let lane = parsed.lane.map { $0 == "tech" ? "tech" : "conversation" }
                return RerankResult(relevanceScore: score, tldr: tldr, whyThis: why, lane: lane)
            }
        } catch {
            // Fall through to fallback
        }
        // Fallback: neutral score, use source lane, use title as TLDR
        return RerankResult(relevanceScore: 5, tldr: row.title, whyThis: "from \(row.sourceName)", lane: row.sourceLane)
    }

    // MARK: - Interest profile

    private func loadBlurb(app: Application) throws -> String {
        let path = app.directory.workingDirectory + "Data/interests.md"
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func ensureProfileEmbedding(
        app: Application,
        ollama: OllamaClient,
        sql: any SQLDatabase
    ) async throws -> [Double] {
        let blurb = try loadBlurb(app: app)

        // Load current stored profile (if any)
        struct Row: Decodable { let id: UUID; let blurb: String; let embedding_text: String? }
        let existing = try await sql.raw("""
            SELECT id, blurb, embedding::text AS embedding_text
            FROM interest_profile
            ORDER BY updated_at DESC NULLS LAST
            LIMIT 1
            """).first(decoding: Row.self)

        if let existing = existing, existing.blurb == blurb, let text = existing.embedding_text, let vec = parsePGVector(text) {
            return vec
        }

        // Embed fresh
        let embedding = try await ollama.embed(text: blurb)

        if let existing = existing {
            try await sql.raw("""
                UPDATE interest_profile
                SET blurb = \(bind: blurb),
                    embedding = \(unsafeRaw: "'\(pgvectorLiteral(embedding))'::vector"),
                    version = version + 1,
                    updated_at = NOW()
                WHERE id = \(bind: existing.id)
                """).run()
        } else {
            try await sql.raw("""
                INSERT INTO interest_profile (id, blurb, embedding, version, updated_at)
                VALUES (\(bind: UUID()),
                        \(bind: blurb),
                        \(unsafeRaw: "'\(pgvectorLiteral(embedding))'::vector"),
                        1, NOW())
                """).run()
        }
        return embedding
    }

    // MARK: - Helpers

    private struct UnScoredRow: Decodable {
        let id: UUID
        let title: String
        let body: String?
        let source_name: String
        let source_lane: String

        var sourceName: String { source_name }
        var sourceLane: String { source_lane }
    }
}

// NOTE: parsePGVector moved to Helpers/VectorMath.swift; stripTags to Helpers/HTMLHelpers.swift.
