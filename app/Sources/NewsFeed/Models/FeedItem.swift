import Fluent
import Foundation
import Vapor

final class FeedItem: Model, @unchecked Sendable {
    static let schema = "feed_items"

    @ID(key: .id) var id: UUID?
    @Parent(key: "source_id") var source: FeedSource
    @Field(key: "external_id") var externalId: String
    @Field(key: "url") var url: String
    @Field(key: "title") var title: String
    @OptionalField(key: "body") var body: String?
    @OptionalField(key: "published_at") var publishedAt: Date?
    @Timestamp(key: "fetched_at", on: .create) var fetchedAt: Date?

    init() {}

    init(sourceID: UUID, externalID: String, url: String, title: String,
         body: String? = nil, publishedAt: Date? = nil) {
        self.$source.id = sourceID
        self.externalId = externalID
        self.url = url
        self.title = title
        self.body = body
        self.publishedAt = publishedAt
    }
}
