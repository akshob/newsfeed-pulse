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
        let userID = try user.requireID()
        req.logger.info("onboarding/submit: user=\(user.email)")

        let form: Form
        do {
            form = try req.content.decode(Form.self)
        } catch {
            req.logger.error("onboarding/submit: form decode failed: \(String(reflecting: error))")
            throw error
        }
        let blurb = composeBlurb(categories: form.categories ?? [], freeform: form.blurb ?? "")
        req.logger.info("onboarding/submit: composed blurb len=\(blurb.count) categories=\(form.categories ?? [])")

        guard !blurb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return req.redirect(to: "/onboarding?err=empty")
        }
        do {
            try await upsertUserProfile(userID: userID, newBlurb: blurb, on: req)
        } catch {
            req.logger.error("onboarding/submit: upsertUserProfile failed for \(user.email): \(String(reflecting: error))")
            throw error
        }
        req.logger.info("onboarding/submit: success for \(user.email)")
        return req.redirect(to: "/?msg=interests_saved")
    }
}
