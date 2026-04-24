import FeedKit
import Fluent
import Foundation
import Vapor

struct IngestCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "Fetch all active feed sources and upsert new items" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let sources = try await FeedSource.query(on: app.db)
            .filter(\.$active == true)
            .all()

        var totalInserted = 0
        for source in sources {
            do {
                let inserted = try await ingest(source: source, on: app)
                context.console.print("[\(source.name)] +\(inserted)")
                totalInserted += inserted
            } catch {
                context.console.error("[\(source.name)] error: \(error)")
            }
        }
        context.console.print("Ingest complete: \(totalInserted) new items across \(sources.count) sources")
    }

    private struct Raw {
        let externalID: String
        let url: String
        let title: String
        let body: String?
        let pub: Date?
    }

    private func ingest(source: FeedSource, on app: Application) async throws -> Int {
        var headers = HTTPHeaders()
        headers.add(name: "User-Agent", value: "pulse-newsfeed/0.1 by akshob")

        let response = try await app.client.get(URI(string: source.url), headers: headers)

        guard var buffer = response.body else { return 0 }
        let bytes = buffer.readableBytes
        guard let data = buffer.readData(length: bytes) else { return 0 }

        let parser = FeedParser(data: data)
        guard let feed = try? parser.parse().get() else { return 0 }

        let items: [Raw]
        switch feed {
        case .rss(let rss):
            items = (rss.items ?? []).compactMap { item in
                guard let title = item.title, let link = item.link else { return nil }
                return Raw(
                    externalID: item.guid?.value ?? link,
                    url: link,
                    title: title,
                    body: item.description,
                    pub: item.pubDate
                )
            }
        case .atom(let atom):
            items = (atom.entries ?? []).compactMap { entry in
                guard let title = entry.title,
                      let link = entry.links?.first?.attributes?.href
                else { return nil }
                return Raw(
                    externalID: entry.id ?? link,
                    url: link,
                    title: title,
                    body: entry.summary?.value ?? entry.content?.value,
                    pub: entry.updated ?? entry.published
                )
            }
        case .json:
            items = []
        }

        guard let sourceID = source.id else { return 0 }

        var inserted = 0
        for i in items {
            let exists = try await FeedItem.query(on: app.db)
                .filter(\.$source.$id == sourceID)
                .filter(\.$externalId == i.externalID)
                .first()
            if exists == nil {
                try await FeedItem(
                    sourceID: sourceID,
                    externalID: i.externalID,
                    url: i.url,
                    title: i.title,
                    body: i.body,
                    publishedAt: i.pub
                ).save(on: app.db)
                inserted += 1
            }
        }
        return inserted
    }
}
