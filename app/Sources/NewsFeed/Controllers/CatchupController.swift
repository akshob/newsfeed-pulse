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
    //
    // Side effect: records a `view` engagement so the feed query can drop
    // articles the user has already opened. Treats any click as a "read"
    // signal — duration tracking is a future refinement.
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

        // Record a view engagement (best-effort — never block the response).
        // We do NOT upsert; a row per click is fine since the feed query
        // only looks at the latest event. Skip the write when the user
        // already has a more committed action (keep/skip) for this item —
        // re-opening to re-read shouldn't downgrade the signal.
        if let user = try? req.auth.require(User.self) {
            do {
                let userID = try user.requireID()
                let latestEvent = try await Engagement.query(on: req.db)
                    .filter(\.$item.$id == id)
                    .filter(\.$user.$id == userID)
                    .sort(\.$createdAt, .descending)
                    .first()?.event
                if latestEvent != "keep" && latestEvent != "skip" {
                    try await Engagement(itemID: id, userID: userID, event: "view")
                        .save(on: req.db)
                }
            } catch {
                req.logger.warning("catchup: failed to record view engagement: \(error)")
            }
        }

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
