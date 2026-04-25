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
        let userID = try user.requireID()
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == userID).first()
        if profile == nil { return req.redirect(to: "/onboarding") }

        let items = try await loadRankedFeed(on: req, userID: userID, limit: 25)
        let lastIngestAt = try await loadLastIngestAt(on: req)
        return htmlResponse(FeedView.render(
            items: items,
            userEmail: user.email,
            lastIngestAt: lastIngestAt,
            message: try? req.query.get(String.self, at: "msg")
        ))
    }

    // GET /raw
    func feedRaw(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let items = try await loadRankedFeed(on: req, userID: userID, limit: 50, orderByScore: false)
        let lastIngestAt = try await loadLastIngestAt(on: req)
        return htmlResponse(FeedView.render(
            items: items,
            userEmail: user.email,
            title: "pulse · raw",
            lastIngestAt: lastIngestAt
        ))
    }
}
