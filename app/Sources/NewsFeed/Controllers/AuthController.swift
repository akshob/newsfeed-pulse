import Fluent
import Foundation
import Vapor

struct AuthController {
    func boot(routes: any RoutesBuilder) {
        routes.get("login", use: self.loginForm)
        routes.get("signup", use: self.signupForm)

        // Per-IP rate limits on POST routes — defense against credential-stuffing
        // and invite-code grinding. Applied only to submit handlers so GET
        // traffic isn't throttled.
        routes.grouped(RateLimitMiddleware(maxEvents: 10, window: 300))
              .post("login", use: self.loginSubmit)
        routes.grouped(RateLimitMiddleware(maxEvents: 5, window: 3600))
              .post("signup", use: self.signupSubmit)
    }

    // GET /login
    func loginForm(req: Request) async throws -> Response {
        if req.auth.has(User.self) { return req.redirect(to: "/") }
        let msg = try? req.query.get(String.self, at: "msg")
        let err = try? req.query.get(String.self, at: "err")
        return htmlResponse(LoginView.render(message: msg, error: err))
    }

    // POST /login
    func loginSubmit(req: Request) async throws -> Response {
        struct Form: Content { var email: String; var password: String }
        let ip = RateLimitMiddleware.clientKey(from: req)
        let form: Form
        do {
            form = try req.content.decode(Form.self)
        } catch {
            authLog(req, "login/submit: form decode failed (ip=\(ip)): \(String(reflecting: error))", level: .error)
            throw error
        }
        let email = form.email.lowercased().trimmingCharacters(in: .whitespaces)
        guard let user = try await User.query(on: req.db).filter(\.$email == email).first(),
              (try? user.verify(password: form.password)) == true else {
            authLog(req, "login/submit: invalid email=\(email) ip=\(ip)", level: .warning)
            return req.redirect(to: "/login?err=invalid")
        }
        req.auth.login(user)
        req.session.authenticate(user)
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == user.requireID()).first()
        let target = profile == nil ? "/onboarding" : "/"
        authLog(req, "login/submit: success email=\(email) ip=\(ip) redirect=\(target)")
        return req.redirect(to: target)
    }

    // GET /signup
    func signupForm(req: Request) async throws -> Response {
        if req.auth.has(User.self) { return req.redirect(to: "/") }
        let code = (try? req.query.get(String.self, at: "code")) ?? ""
        let err = try? req.query.get(String.self, at: "err")
        return htmlResponse(SignupView.render(prefilledCode: code, error: err))
    }

    // POST /signup
    func signupSubmit(req: Request) async throws -> Response {
        struct Form: Content {
            var code: String
            var email: String
            var password: String
            var confirm_password: String
        }
        let ip = RateLimitMiddleware.clientKey(from: req)
        let form: Form
        do {
            form = try req.content.decode(Form.self)
        } catch {
            authLog(req, "signup/submit: form decode failed (ip=\(ip)): \(String(reflecting: error))", level: .error)
            throw error
        }
        let code = form.code.lowercased().trimmingCharacters(in: .whitespaces)
        let email = form.email.lowercased().trimmingCharacters(in: .whitespaces)

        func bounce(_ err: String) -> Response {
            authLog(req, "signup/submit: \(err) email=\(email) code=\(code) ip=\(ip)", level: .warning)
            return req.redirect(to: "/signup?err=\(err)&code=\(code)")
        }

        guard let invite = try await Invite.query(on: req.db)
            .filter(\.$code == code)
            .filter(\.$usedAt == nil)
            .first() else { return bounce("invalid_code") }
        guard email.contains("@"), email.count >= 3 else { return bounce("bad_email") }
        guard form.password.count >= 8 else { return bounce("short_password") }
        guard form.password == form.confirm_password else { return bounce("mismatch") }
        if try await User.query(on: req.db).filter(\.$email == email).first() != nil {
            return bounce("email_taken")
        }

        let user = User(email: email, passwordHash: try Bcrypt.hash(form.password))
        try await user.save(on: req.db)

        invite.usedAt = Date()
        invite.$usedBy.id = try user.requireID()
        try await invite.save(on: req.db)

        req.auth.login(user)
        req.session.authenticate(user)
        authLog(req, "signup/submit: success email=\(email) code=\(code) ip=\(ip)")
        return req.redirect(to: "/onboarding")
    }
}
