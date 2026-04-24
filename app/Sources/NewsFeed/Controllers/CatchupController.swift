import Fluent
import Foundation
import Vapor

struct CatchupController {
    func boot(routes: any RoutesBuilder) {
        routes.get("catchup", ":id", use: self.catchup)
    }

    // GET /catchup/:id
    // Returns either the cached LLM explainer (if available) or an iframe
    // fallback to the original article with a banner. Never triggers LLM
    // inference on click — that's the hourly cron pipeline's job.
    func catchup(req: Request) async throws -> Response {
        guard let id = req.parameters.get("id", as: UUID.self),
              let item = try await FeedItem.query(on: req.db)
                .filter(\.$id == id)
                .with(\.$source)
                .first() else {
            throw Abort(.notFound)
        }
        let score = try await ItemScore.query(on: req.db)
            .filter(\.$item.$id == id).first()
        let isHX = req.headers.first(name: "HX-Request") == "true"

        if let cached = score?.catchupHTML, !cached.isEmpty {
            return htmlResponse(isHX
                ? CatchupView.renderFragment(item: item, score: score, explainerHTML: cached)
                : CatchupView.renderPage(item: item, score: score, explainerHTML: cached))
        } else {
            return htmlResponse(isHX
                ? CatchupView.renderIframeFragment(item: item, score: score)
                : CatchupView.renderIframePage(item: item, score: score))
        }
    }
}
