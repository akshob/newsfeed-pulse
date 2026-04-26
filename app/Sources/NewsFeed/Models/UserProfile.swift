import Fluent
import Foundation
import Vapor

// NOTE: The underlying table has an `embedding vector(768)` column (pgvector)
// managed via raw SQL. Fluent model exposes everything else.
final class UserProfile: Model, @unchecked Sendable {
    static let schema = "user_profiles"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "blurb") var blurb: String
    /// Categories the user explicitly selected via checkboxes — source of
    /// truth for filtering. Replaces the prior substring-match-the-blurb
    /// approach which was prone to false positives ("no politics" → tick
    /// politics).
    @OptionalField(key: "categories") var categories: [String]?
    /// Categories the LLM extracted from the freeform body that the user
    /// wants excluded ("skip startup pitches" → exclude tech). Filtered
    /// out of feed even if the source's categories overlap with selected.
    @OptionalField(key: "excluded_categories") var excludedCategories: [String]?
    @OptionalField(key: "updated_at") var updatedAt: Date?

    init() {}

    init(userID: UUID, blurb: String, categories: [String] = [], excludedCategories: [String] = []) {
        self.$user.id = userID
        self.blurb = blurb
        self.categories = categories
        self.excludedCategories = excludedCategories
    }
}
