import Fluent
import Foundation
import Vapor

struct SeedFeedsCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "Load Data/feeds.json into the feed_sources table" }

    struct FeedConfig: Codable {
        let name: String
        let url: String
        let lane: String
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let path = context.application.directory.workingDirectory + "Data/feeds.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let feeds = try JSONDecoder().decode([FeedConfig].self, from: data)

        var inserted = 0
        for f in feeds {
            let exists = try await FeedSource.query(on: context.application.db)
                .filter(\.$url == f.url)
                .first()
            if exists == nil {
                try await FeedSource(name: f.name, url: f.url, lane: f.lane)
                    .save(on: context.application.db)
                inserted += 1
            }
        }
        context.console.print("Seeded \(inserted) new feed sources (total in file: \(feeds.count))")
    }
}
