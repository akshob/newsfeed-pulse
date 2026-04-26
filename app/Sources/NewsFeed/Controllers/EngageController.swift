import Fluent
import Foundation
import Vapor

struct EngageController {
    func boot(routes: any RoutesBuilder) {
        routes.post("engage", ":id", use: self.engage)
    }

    // POST /engage/:id — store the user's keep/skip vote for a feed item.
    // Captures the item's similarity at vote time for future analysis of
    // "did embedding match align with user's actual interest?"
    //
    // Side effect on `keep`: fires a background Task that re-embeds the
    // user's profile with kept titles included. Cosine `user_match` shifts
    // toward what they engage with, so the next feed view reorders in
    // their favor — no nightly job required.
    //
    // `skip` already filters at query time (per-user), so it doesn't need
    // an embedding update; using "skipped: <title>" as embedding context
    // would actually move the vector *toward* that title (the embedder
    // reads text positively), which is the opposite of intent.
    func engage(req: Request) async throws -> Response {
        guard let itemID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        struct Form: Content { var event: String }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let form = try req.content.decode(Form.self)
        let event = form.event.trimmingCharacters(in: .whitespaces)
        guard event == "keep" || event == "skip" else {
            throw Abort(.badRequest, reason: "event must be keep or skip")
        }
        let similarity = try await ItemScore.query(on: req.db)
            .filter(\.$item.$id == itemID).first()?.similarity
        try await Engagement(
            itemID: itemID,
            userID: userID,
            event: event,
            similarityAtVote: similarity
        ).save(on: req.db)

        if event == "keep" {
            let app = req.application
            let logger = req.logger
            Task.detached {
                do {
                    try await evolveUserEmbedding(
                        userID: userID,
                        application: app,
                        logger: logger
                    )
                } catch {
                    logger.error("engage/keep: evolveUserEmbedding failed for \(userID): \(error)")
                }
            }
        }

        return Response(status: .noContent)
    }
}
