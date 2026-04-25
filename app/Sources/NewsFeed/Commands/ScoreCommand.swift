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

        // 1. Ensure interest profile embedding exists and matches current blurb.
        // The returned profile_updated_at is what we compare item_scores.scored_at
        // against to detect rows that need to be re-rescored after a blurb change.
        let profileEmbedding: [Double]
        let profileUpdatedAt: Date?
        do {
            (profileEmbedding, profileUpdatedAt) = try await ensureProfileEmbedding(
                app: app, ollama: ollama, sql: sql
            )
        } catch {
            context.console.error("score: profile embed failed: \(error)")
            throw error
        }
        context.console.print("profile embedding ready (dim=\(profileEmbedding.count))")

        // 2. Phase 1 — global scoring of items lacking a fresh global score.
        // "Stale" includes both never-scored AND scored-before-blurb-change.
        context.console.print("score: phase 1 — global scoring")
        let rows: [ScoringItemRow]
        do {
            rows = try await sql.raw("""
                SELECT fi.id AS id, fi.title AS title, fi.body AS body,
                       fs.name AS source_name, fs.lane AS source_lane
                FROM feed_items fi
                JOIN feed_sources fs ON fi.source_id = fs.id
                LEFT JOIN item_scores isc ON isc.item_id = fi.id
                WHERE isc.id IS NULL
                   OR (isc.scored_at IS NOT NULL
                       AND \(bind: profileUpdatedAt) IS NOT NULL
                       AND isc.scored_at < \(bind: profileUpdatedAt))
                ORDER BY fi.fetched_at DESC
                LIMIT \(bind: limit)
                """).all(decoding: ScoringItemRow.self)
        } catch {
            context.console.error("score: stale-item query failed: \(error)")
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

        // 3. Phase 2 — per-user rerank for items lacking a fresh user-side score.
        // Each user's blurb (from user_profiles.blurb) drives a separate rerank
        // so the displayed tldr/why_this/relevance reflect that specific user.
        // Same logic also runs from OnboardingController right after onboarding.
        try await scorePerUserAcrossAllUsers(
            app: app,
            sql: sql,
            model: model,
            context: context
        )
    }

    // MARK: - Phase 2 wrapper (loops users, delegates to rescoreUser)

    private struct UserToScore: Decodable {
        let user_id: UUID
        let email: String
    }

    private func scorePerUserAcrossAllUsers(
        app: Application,
        sql: any SQLDatabase,
        model: String,
        context: CommandContext
    ) async throws {
        context.console.print("score: phase 2 — per-user scoring")
        let users = try await sql.raw("""
            SELECT u.id AS user_id, u.email AS email
            FROM users u
            JOIN user_profiles p ON p.user_id = u.id
            WHERE p.blurb IS NOT NULL AND length(p.blurb) > 0
            ORDER BY p.updated_at DESC NULLS LAST
            """).all(decoding: UserToScore.self)
        context.console.print("  \(users.count) users with profiles")

        for user in users {
            do {
                _ = try await rescoreUser(
                    userID: user.user_id,
                    application: app,
                    logger: app.logger,
                    model: model
                )
            } catch {
                context.console.error("  [\(user.email)] phase 2 failed: \(error)")
            }
        }
    }

    // MARK: - Single global item

    private func scoreOne(
        row: ScoringItemRow,
        blurb: String,
        profileEmbedding: [Double],
        ollama: OllamaClient,
        model: String,
        sql: any SQLDatabase
    ) async throws {
        // Build text to embed — title is highest signal, body adds context.
        // Re-embedding on rescore is wasteful but cheap (nomic on localhost,
        // ~150ms each, deterministic) — keeping the path uniform for now.
        let bodyClean = row.body.map(stripTags) ?? ""
        let embedText = "\(row.title)\n\n\(bodyClean.prefix(800))"

        let itemEmbedding = try await ollama.embed(text: embedText)
        let similarity = cosineSimilarity(profileEmbedding, itemEmbedding)

        // Dedup against the recent cluster heads. Excludes already-marked
        // duplicates so chains can't form (B→A, C→B); every cluster member
        // points at the same head.
        let dupOfItemID = try await findDuplicate(
            embedding: itemEmbedding,
            excludingItemID: row.id,
            sql: sql
        )

        let rerank = await llmRerank(
            ollama: ollama,
            model: model,
            blurb: blurb,
            row: row,
            body: bodyClean
        )

        // UPSERT so re-rescore (after blurb change) updates in place rather
        // than failing on the UNIQUE(item_id) constraint. dup_of_item_id is
        // intentionally NOT in the SET clause — the dedup decision is based
        // on cosine similarity which doesn't depend on the blurb, so the
        // existing cluster head stays stable across rescores.
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
            ON CONFLICT (item_id) DO UPDATE SET
              embedding = EXCLUDED.embedding,
              similarity = EXCLUDED.similarity,
              relevance_score = EXCLUDED.relevance_score,
              tldr = EXCLUDED.tldr,
              why_this = EXCLUDED.why_this,
              lane = EXCLUDED.lane,
              scored_at = EXCLUDED.scored_at
            """).run()
    }

    // MARK: - Dedup

    private struct DupNeighbor: Decodable {
        let id: UUID
        let distance: Double
    }

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

    // MARK: - Interest profile (global blurb)

    /// Reads the generic global-news evaluator profile. This file is committed
    /// to the repo (unlike Data/interests.md which was historically gitignored
    /// as the owner's personal blurb). The global blurb intentionally covers
    /// all 7 onboarding categories evenly so brand-new users see a balanced
    /// fallback feed before per-user scoring runs against their own blurb.
    private func loadBlurb(app: Application) throws -> String {
        let path = app.directory.workingDirectory + "Data/global_news_blurb.md"
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func ensureProfileEmbedding(
        app: Application,
        ollama: OllamaClient,
        sql: any SQLDatabase
    ) async throws -> (embedding: [Double], updatedAt: Date?) {
        let blurb = try loadBlurb(app: app)

        struct Row: Decodable {
            let id: UUID
            let blurb: String
            let embedding_text: String?
            let updated_at: Date?
        }
        let existing = try await sql.raw("""
            SELECT id, blurb, embedding::text AS embedding_text, updated_at
            FROM interest_profile
            ORDER BY updated_at DESC NULLS LAST
            LIMIT 1
            """).first(decoding: Row.self)

        if let existing = existing,
           existing.blurb == blurb,
           let text = existing.embedding_text,
           let vec = parsePGVector(text) {
            return (vec, existing.updated_at)
        }

        // Blurb changed (or no row yet) — re-embed and bump updated_at, which
        // marks every existing item_scores row as stale on the next pass.
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
        // We just wrote NOW() — round-trip would be more accurate but Date()
        // here is within milliseconds and good enough for the staleness gate.
        return (embedding, Date())
    }
}
