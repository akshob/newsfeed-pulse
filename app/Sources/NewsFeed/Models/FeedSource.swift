import Fluent
import Foundation
import Vapor

final class FeedSource: Model, @unchecked Sendable {
    static let schema = "feed_sources"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "url") var url: String
    @Field(key: "lane") var lane: String
    @Field(key: "active") var active: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, url: String, lane: String, active: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.lane = lane
        self.active = active
    }
}
