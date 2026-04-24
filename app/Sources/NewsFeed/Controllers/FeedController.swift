import Fluent
import Foundation
import Vapor

struct FeedController {
    func boot(routes: any RoutesBuilder) {
        routes.get(use: self.feedHome)
        routes.get("raw", use: self.feedRaw)
    }

    // GET /
    func feedHome(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == user.requireID()).first()
        if profile == nil { return req.redirect(to: "/onboarding") }

        let items = try await loadRankedFeed(on: req, limit: 25)
        return htmlResponse(FeedView.render(
            items: items,
            userEmail: user.email,
            message: try? req.query.get(String.self, at: "msg")
        ))
    }

    // GET /raw
    func feedRaw(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let items = try await loadRankedFeed(on: req, limit: 50, orderByScore: false)
        return htmlResponse(FeedView.render(items: items, userEmail: user.email, title: "pulse / raw"))
    }
}
