import Fluent
import Foundation
import Vapor

final class User: Model, Content, Authenticatable, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "email") var email: String
    @Field(key: "password_hash") var passwordHash: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, email: String, passwordHash: String) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
    }
}

extension User: ModelAuthenticatable {
    static let usernameKey: KeyPath<User, FieldProperty<User, String>> = \User.$email
    static let passwordHashKey: KeyPath<User, FieldProperty<User, String>> = \User.$passwordHash

    func verify(password: String) throws -> Bool {
        try Bcrypt.verify(password, created: self.passwordHash)
    }
}

extension User: ModelSessionAuthenticatable {}
