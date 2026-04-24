import Fluent
import Foundation
import Vapor

struct AuthController {
    func boot(routes: any RoutesBuilder) {
        routes.get("login", use: self.loginForm)
        routes.post("login", use: self.loginSubmit)
        routes.get("signup", use: self.signupForm)
        routes.post("signup", use: self.signupSubmit)
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
        let form = try req.content.decode(Form.self)
        let email = form.email.lowercased().trimmingCharacters(in: .whitespaces)
        guard let user = try await User.query(on: req.db).filter(\.$email == email).first(),
              (try? user.verify(password: form.password)) == true else {
            return req.redirect(to: "/login?err=invalid")
        }
        req.auth.login(user)
        req.session.authenticate(user)
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == user.requireID()).first()
        return req.redirect(to: profile == nil ? "/onboarding" : "/")
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
        let form = try req.content.decode(Form.self)
        let code = form.code.lowercased().trimmingCharacters(in: .whitespaces)
        let email = form.email.lowercased().trimmingCharacters(in: .whitespaces)

        func bounce(_ err: String) -> Response {
            req.redirect(to: "/signup?err=\(err)&code=\(code)")
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
        return req.redirect(to: "/onboarding")
    }
}
