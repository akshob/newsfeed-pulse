import Fluent
import Foundation
import Vapor

final class Invite: Model, @unchecked Sendable {
    static let schema = "invites"

    @ID(key: .id) var id: UUID?
    @Field(key: "code") var code: String
    @OptionalParent(key: "created_by_user_id") var createdBy: User?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "used_at") var usedAt: Date?
    @OptionalParent(key: "used_by_user_id") var usedBy: User?

    init() {}

    init(code: String, createdByUserID: UUID? = nil) {
        self.code = code
        self.$createdBy.id = createdByUserID
    }
}

/// Generate a short, readable invite code like "k3p7-qza8-mnv2".
/// Alphabet avoids ambiguous characters (0/1/o/l).
func generateInviteCode() -> String {
    let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
    let parts = (0..<3).map { _ in
        String((0..<4).map { _ in alphabet.randomElement()! })
    }
    return parts.joined(separator: "-")
}
