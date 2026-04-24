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
    func engage(req: Request) async throws -> Response {
        guard let itemID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        struct Form: Content { var event: String }
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(Form.self)
        let event = form.event.trimmingCharacters(in: .whitespaces)
        guard event == "keep" || event == "skip" else {
            throw Abort(.badRequest, reason: "event must be keep or skip")
        }
        let similarity = try await ItemScore.query(on: req.db)
            .filter(\.$item.$id == itemID).first()?.similarity
        try await Engagement(
            itemID: itemID,
            userID: try user.requireID(),
            event: event,
            similarityAtVote: similarity
        ).save(on: req.db)
        return Response(status: .noContent)
    }
}
