import Fluent
import Foundation
import Vapor

struct CreateInviteCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "Generate a one-shot invite code for /signup" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let code = generateInviteCode()
        let invite = Invite(code: code)
        try await invite.save(on: app.db)
        context.console.print("")
        context.console.print("✓ invite code:  \(code)")
        context.console.print("  share URL:    https://pulse.akshob.com/signup?code=\(code)")
        context.console.print("")
    }
}
