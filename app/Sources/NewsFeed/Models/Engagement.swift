import Fluent
import Foundation
import Vapor

final class Engagement: Model, @unchecked Sendable {
    static let schema = "engagements"

    @ID(key: .id) var id: UUID?
    @Parent(key: "item_id") var item: FeedItem
    @OptionalParent(key: "user_id") var user: User?
    @Field(key: "event") var event: String  // "keep" | "skip"
    @OptionalField(key: "similarity_at_vote") var similarityAtVote: Float?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(itemID: UUID, userID: UUID?, event: String, similarityAtVote: Float? = nil) {
        self.$item.id = itemID
        self.$user.id = userID
        self.event = event
        self.similarityAtVote = similarityAtVote
    }
}
