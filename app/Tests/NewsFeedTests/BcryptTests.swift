@testable import NewsFeed
import Foundation
import Testing
import Vapor

@Suite("Bcrypt password hashing")
struct BcryptTests {
    @Test func hashThenVerifySucceedsForSamePassword() throws {
        let password = "correct horse battery staple"
        let hash = try Bcrypt.hash(password)
        #expect(try Bcrypt.verify(password, created: hash))
    }

    @Test func verifyFailsForWrongPassword() throws {
        let hash = try Bcrypt.hash("secret123")
        #expect(try Bcrypt.verify("wrong", created: hash) == false)
    }

    @Test func sameInputProducesDifferentHashes() throws {
        // Bcrypt includes a random salt — different hash each time, both verify
        let a = try Bcrypt.hash("samePassword!")
        let b = try Bcrypt.hash("samePassword!")
        #expect(a != b)
        #expect(try Bcrypt.verify("samePassword!", created: a))
        #expect(try Bcrypt.verify("samePassword!", created: b))
    }

    @Test func verifyFailsForTamperedHash() throws {
        var hash = try Bcrypt.hash("pw")
        // flip the last character — should no longer verify
        hash = String(hash.dropLast()) + (hash.last == "A" ? "B" : "A")
        #expect(throws: Never.self) {
            let ok = (try? Bcrypt.verify("pw", created: hash)) ?? false
            #expect(ok == false)
        }
    }
}

@Suite("User.verify password roundtrip")
struct UserVerifyTests {
    @Test func modelLevelRoundtrip() throws {
        let pw = "hello-world-12345"
        let user = User(email: "a@b.com", passwordHash: try Bcrypt.hash(pw))
        #expect(try user.verify(password: pw))
        #expect(try user.verify(password: "not-it") == false)
    }
}
