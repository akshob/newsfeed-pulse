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
    /// truth for explicit intent. Stays empty if the user submitted the
    /// onboarding form without ticking anything.
    @OptionalField(key: "categories") var categories: [String]?
    /// Categories the LLM inferred from the freeform body. Kept separate
    /// from `categories` so the onboarding form doesn't false-positive-
    /// tick checkboxes for inferred topics; tags are rendered as a
    /// distinct row instead. Filter logic unions both arrays.
    @OptionalField(key: "inferred_categories") var inferredCategories: [String]?
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
