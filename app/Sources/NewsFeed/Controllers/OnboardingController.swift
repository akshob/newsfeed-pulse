import Fluent
import Foundation
import Vapor

struct OnboardingController {
    func boot(routes: any RoutesBuilder) {
        routes.get("onboarding", use: self.onboardingForm)
        routes.post("onboarding", use: self.onboardingSubmit)
    }

    // GET /onboarding
    func onboardingForm(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == user.requireID()).first()
        return htmlResponse(OnboardingView.render(
            email: user.email,
            currentBlurb: profile?.blurb,
            message: try? req.query.get(String.self, at: "msg"),
            error: try? req.query.get(String.self, at: "err")
        ))
    }

    // POST /onboarding — persist categories + blurb as an embedded user_profile.
    func onboardingSubmit(req: Request) async throws -> Response {
        struct Form: Content {
            var categories: [String]?
            var blurb: String?
        }
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(Form.self)
        let blurb = composeBlurb(categories: form.categories ?? [], freeform: form.blurb ?? "")
        guard !blurb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return req.redirect(to: "/onboarding?err=empty")
        }
        try await upsertUserProfile(userID: try user.requireID(), blurb: blurb, on: req)
        return req.redirect(to: "/?msg=interests_saved")
    }
}
