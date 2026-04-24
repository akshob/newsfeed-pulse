import Fluent
import Foundation
import Vapor

// NOTE: The underlying table has an `embedding vector(768)` column used for
// similarity search. Fluent doesn't model the vector column — we manage it
// via raw SQL in ScoreCommand. The Model here is for read/display only.
final class ItemScore: Model, @unchecked Sendable {
    static let schema = "item_scores"

    @ID(key: .id) var id: UUID?
    @Parent(key: "item_id") var item: FeedItem
    @OptionalField(key: "similarity") var similarity: Float?
    @OptionalField(key: "relevance_score") var relevanceScore: Int?
    @OptionalField(key: "tldr") var tldr: String?
    @OptionalField(key: "why_this") var whyThis: String?
    @OptionalField(key: "lane") var predictedLane: String?
    @OptionalField(key: "scored_at") var scoredAt: Date?
    @OptionalField(key: "catchup_html") var catchupHTML: String?
    @OptionalField(key: "catchup_generated_at") var catchupGeneratedAt: Date?

    init() {}
}
