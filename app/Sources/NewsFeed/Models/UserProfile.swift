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
    @OptionalField(key: "updated_at") var updatedAt: Date?

    init() {}

    init(userID: UUID, blurb: String) {
        self.$user.id = userID
        self.blurb = blurb
    }
}
