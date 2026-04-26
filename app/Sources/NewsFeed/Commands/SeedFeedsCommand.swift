import Fluent
import Foundation
import SQLKit
import Vapor

struct SeedFeedsCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "Load Data/feeds.json into the feed_sources table; UPSERT categories on URL match." }

    struct FeedConfig: Codable {
        let name: String
        let url: String
        let lane: String
        /// Optional in JSON for backward compat; missing = treat as empty.
        /// New deployments should always set it so feed query filtering works.
        let categories: [String]?
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let path = context.application.directory.workingDirectory + "Data/feeds.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let feeds = try JSONDecoder().decode([FeedConfig].self, from: data)

        guard let sql = context.application.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "expected SQLDatabase")
        }

        var inserted = 0
        var updated = 0
        for f in feeds {
            let cats = f.categories ?? []
            let catsLiteral = cats.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
                .joined(separator: ",")
            let arrayLiteral = "ARRAY[\(catsLiteral)]::TEXT[]"

            let existing = try await FeedSource.query(on: context.application.db)
                .filter(\.$url == f.url)
                .first()

            if let existing = existing, let existingID = existing.id {
                // UPSERT semantics: refresh categories (and lane) on every
                // seed-feeds run so changes to feeds.json propagate without
                // having to delete + re-insert.
                try await sql.raw("""
                    UPDATE feed_sources
                    SET name = \(bind: f.name),
                        lane = \(bind: f.lane),
                        categories = \(unsafeRaw: arrayLiteral)
                    WHERE id = \(bind: existingID)
                    """).run()
                updated += 1
            } else {
                try await sql.raw("""
                    INSERT INTO feed_sources (id, name, url, lane, categories, active, created_at)
                    VALUES (\(bind: UUID()), \(bind: f.name), \(bind: f.url), \(bind: f.lane),
                            \(unsafeRaw: arrayLiteral), TRUE, NOW())
                    """).run()
                inserted += 1
            }
        }
        context.console.print("Seeded: +\(inserted) inserted, ~\(updated) updated (total in file: \(feeds.count))")
    }
}
