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
        "Score feed_items: phase 1 = global embed/dedup/fallback rerank; phase 2 = per-user LLM rerank against each user's blurb"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        context.console.print("score: starting")
        let app = context.application
        let limit = signature.limit ?? 100
        let model = signature.model
            ?? Environment.get("OLLAMA_CHAT_MODEL")
            ?? "llama3.2:3b"
        let ollama = OllamaClient(client: app.client)
        context.console.print("score: using chat model \(model)")

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

        // 2. Phase 1 — global scoring of un-scored items (embed + dedup + fallback rerank)
        context.console.print("score: phase 1 — global scoring of un-scored items")
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

        context.console.print("  scoring \(rows.count) items globally…")

        let globalBlurb = try loadBlurb(app: app)
        var scored = 0
        for row in rows {
            do {
                try await scoreOne(row: row,
                                   blurb: globalBlurb,
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
        context.console.print("  phase 1 done: \(scored)/\(rows.count) scored")

        // 3. Phase 2 — per-user LLM rerank for items lacking a fresh user-side score.
        // Each user's blurb (from user_profiles.blurb) drives a separate rerank
        // so the displayed tldr/why_this/relevance reflect that specific user's
        // interests rather than the owner's global interests.md.
        try await scorePerUser(
            app: app,
            ollama: ollama,
            model: model,
            sql: sql,
            context: context
        )
    }

    // MARK: - Phase 2: per-user scoring

    private struct UserToScore: Decodable {
        let user_id: UUID
        let email: String
        let blurb: String
        let profile_updated_at: Date?
    }

    private struct PerUserItemRow: Decodable {
        let id: UUID
        let title: String
        let body: String?
        let source_name: String
        let source_lane: String
    }

    private func scorePerUser(
        app: Application,
        ollama: OllamaClient,
        model: String,
        sql: any SQLDatabase,
        context: CommandContext
    ) async throws {
        context.console.print("score: phase 2 — per-user scoring")

        // Active users with a profile we can score against. No blurb → skip.
        let users = try await sql.raw("""
            SELECT u.id AS user_id, u.email AS email,
                   p.blurb AS blurb, p.updated_at AS profile_updated_at
            FROM users u
            JOIN user_profiles p ON p.user_id = u.id
            WHERE p.blurb IS NOT NULL AND length(p.blurb) > 0
            ORDER BY p.updated_at DESC NULLS LAST
            """).all(decoding: UserToScore.self)
        context.console.print("  \(users.count) users with profiles")

        for user in users {
            // Items eligible for per-user scoring:
            //   - already globally scored (so we have an embedding + dedup decision)
            //   - not a duplicate
            //   - recent enough that the score is worth computing (< 7 days)
            //   - either no per-user score yet, OR the user's per-item score is
            //     older than their current profile (blurb changed → stale)
            let items: [PerUserItemRow] = try await sql.raw("""
                SELECT fi.id AS id, fi.title AS title, fi.body AS body,
                       fs.name AS source_name, fs.lane AS source_lane
                FROM feed_items fi
                JOIN feed_sources fs ON fi.source_id = fs.id
                JOIN item_scores isc ON isc.item_id = fi.id
                LEFT JOIN user_item_scores uis
                  ON uis.item_id = fi.id AND uis.user_id = \(bind: user.user_id)
                WHERE isc.dup_of_item_id IS NULL
                  AND fi.fetched_at > NOW() - INTERVAL '7 days'
                  AND (
                    uis.id IS NULL
                    OR (uis.scored_at IS NOT NULL
                        AND \(bind: user.profile_updated_at) IS NOT NULL
                        AND uis.scored_at < \(bind: user.profile_updated_at))
                  )
                ORDER BY fi.fetched_at DESC
                LIMIT 200
                """).all(decoding: PerUserItemRow.self)

            context.console.print("  user \(user.email): \(items.count) items to score")

            var done = 0
            for item in items {
                do {
                    let bodyClean = item.body.map(stripTags) ?? ""
                    let row = UnScoredRow(
                        id: item.id, title: item.title, body: item.body,
                        source_name: item.source_name, source_lane: item.source_lane
                    )
                    let rerank = await llmRerank(
                        ollama: ollama, model: model,
                        blurb: user.blurb, row: row, body: bodyClean
                    )
                    try await sql.raw("""
                        INSERT INTO user_item_scores
                          (id, user_id, item_id, relevance_score, tldr, why_this, lane, scored_at)
                        VALUES
                          (\(bind: UUID()),
                           \(bind: user.user_id),
                           \(bind: item.id),
                           \(bind: rerank.relevanceScore),
                           \(bind: rerank.tldr),
                           \(bind: rerank.whyThis),
                           \(bind: rerank.lane ?? item.source_lane),
                           NOW())
                        ON CONFLICT (user_id, item_id) DO UPDATE SET
                          relevance_score = EXCLUDED.relevance_score,
                          tldr = EXCLUDED.tldr,
                          why_this = EXCLUDED.why_this,
                          lane = EXCLUDED.lane,
                          scored_at = EXCLUDED.scored_at
                        """).run()
                    done += 1
                    if done % 10 == 0 {
                        context.console.print("    \(user.email): \(done)/\(items.count)")
                    }
                } catch {
                    context.console.error("    [\(user.email)/\(item.title.prefix(40))] error: \(error)")
                }
            }
            context.console.print("  user \(user.email): scored \(done)/\(items.count)")
        }
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

        // Dedup against the recent cluster heads. We exclude rows that are
        // already marked as duplicates so chains can't form (B→A, C→B);
        // every member of a cluster points at the same head.
        let dupOfItemID = try await findDuplicate(
            embedding: itemEmbedding,
            excludingItemID: row.id,
            sql: sql
        )

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
              (id, item_id, embedding, similarity, relevance_score, tldr, why_this, lane, dup_of_item_id, scored_at)
            VALUES
              (\(bind: UUID()),
               \(bind: row.id),
               \(unsafeRaw: "'\(pgvectorLiteral(itemEmbedding))'::vector"),
               \(bind: Float(similarity)),
               \(bind: rerank.relevanceScore),
               \(bind: rerank.tldr),
               \(bind: rerank.whyThis),
               \(bind: rerank.lane ?? row.sourceLane),
               \(bind: dupOfItemID),
               NOW())
            """).run()
    }

    // MARK: - Dedup

    private struct DupNeighbor: Decodable {
        let id: UUID
        let distance: Double
    }

    /// Nearest scored item within the recency window, restricted to cluster
    /// heads. Returns the canonical item id when the cosine distance is
    /// within threshold, otherwise nil (this item starts a fresh cluster).
    private func findDuplicate(
        embedding: [Double],
        excludingItemID: UUID,
        sql: any SQLDatabase
    ) async throws -> UUID? {
        let vecLiteral = "'\(pgvectorLiteral(embedding))'::vector"
        let recencyClause = "fi.fetched_at > NOW() - INTERVAL '\(DUP_RECENCY_HOURS) hours'"
        let neighbors = try await sql.raw("""
            SELECT fi.id AS id,
                   (isc.embedding <=> \(unsafeRaw: vecLiteral)) AS distance
            FROM item_scores isc
            JOIN feed_items fi ON isc.item_id = fi.id
            WHERE \(unsafeRaw: recencyClause)
              AND isc.dup_of_item_id IS NULL
              AND fi.id <> \(bind: excludingItemID)
            ORDER BY isc.embedding <=> \(unsafeRaw: vecLiteral) ASC
            LIMIT 1
            """).all(decoding: DupNeighbor.self)
        return canonicalIDFromNeighbors(neighbors.map { ($0.id, $0.distance) })
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
