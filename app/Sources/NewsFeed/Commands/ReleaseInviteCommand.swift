import Fluent
import Foundation
import Vapor

/// Re-arm a previously-consumed invite code so it can be used again.
///
/// The orphan-after-delete case (FK `ON DELETE SET NULL`) leaves the invite
/// row with `used_at` set even though `used_by_user_id` is now NULL — the
/// account that consumed it is gone but the audit fact remains. This
/// command clears both fields so the same code can be re-shared without
/// minting a new one.
struct ReleaseInviteCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "code", help: "The invite code to release (e.g. 'xafq-nmrt-gj63')")
        var code: String
    }
    var help: String { "Clear used_at/used_by on an invite so it can be re-used" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let code = signature.code.lowercased().trimmingCharacters(in: .whitespaces)

        guard let invite = try await Invite.query(on: app.db)
            .filter(\.$code == code)
            .first() else {
            context.console.error("✗ no invite with code: \(code)")
            return
        }

        if invite.usedAt == nil && invite.$usedBy.id == nil {
            context.console.print("(already unused — nothing to do)")
            return
        }

        let priorUsedAt = invite.usedAt
        invite.usedAt = nil
        invite.$usedBy.id = nil
        try await invite.save(on: app.db)

        let priorStr = priorUsedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        await AuthFileLogger.shared.append(
            "invite/release: code=\(code) prior_used_at=\(priorStr) source=cli",
            level: "info"
        )
        context.console.print("✓ released \(code) (was used at \(priorStr))")
        context.console.print("  share URL: https://pulse.akshob.com/signup?code=\(code)")
    }
}
