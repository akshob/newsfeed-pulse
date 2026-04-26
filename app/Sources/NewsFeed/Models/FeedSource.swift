import Fluent
import Foundation
import Vapor

final class FeedSource: Model, @unchecked Sendable {
    static let schema = "feed_sources"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "url") var url: String
    /// Two-lane mental model retained for UI styling (tech vs conversation
    /// badge color). The richer `categories` array is the source of truth
    /// for filtering.
    @Field(key: "lane") var lane: String
    /// Multi-tag categories used for hard category filtering in the feed
    /// query (intersected with user's `user_profiles.categories`).
    /// Postgres TEXT[]; Fluent doesn't model array natively so reads/writes
    /// to this field flow through SeedFeedsCommand and FeedQueries via raw
    /// SQL. We keep it on the model so SwiftPM-aware tooling sees the field.
    @OptionalField(key: "categories") var categories: [String]?
    @Field(key: "active") var active: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, url: String, lane: String,
         categories: [String] = [], active: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.lane = lane
        self.categories = categories
        self.active = active
    }
}
