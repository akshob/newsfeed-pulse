import Fluent
import Foundation
import Vapor

final class Engagement: Model, @unchecked Sendable {
    static let schema = "engagements"

    @ID(key: .id) var id: UUID?
    @Parent(key: "item_id") var item: FeedItem
    @Field(key: "event") var event: String  // "keep" | "skip"
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(itemID: UUID, event: String) {
        self.$item.id = itemID
        self.event = event
    }
}
