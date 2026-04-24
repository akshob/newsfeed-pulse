import Fluent
import Foundation
import Vapor

struct AccountController {
    func boot(routes: any RoutesBuilder) {
        routes.get("account", use: self.accountForm)
        routes.post("account", "password", use: self.changePassword)
        routes.post("account", "delete", use: self.deleteAccount)
        routes.post("logout", use: self.logout)
    }

    // GET /account
    func accountForm(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        return htmlResponse(AccountView.render(
            email: user.email,
            message: try? req.query.get(String.self, at: "msg"),
            error: try? req.query.get(String.self, at: "err")
        ))
    }

    // POST /account/password — change password, auto-logout, redirect to /login
    func changePassword(req: Request) async throws -> Response {
        struct Form: Content {
            var current_password: String
            var new_password: String
            var confirm_password: String
        }
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(Form.self)
        func bounce(_ err: String) -> Response { req.redirect(to: "/account?err=\(err)") }
        guard (try? user.verify(password: form.current_password)) == true else { return bounce("current_wrong") }
        guard form.new_password == form.confirm_password else { return bounce("mismatch") }
        guard form.new_password.count >= 8 else { return bounce("short") }

        user.passwordHash = try Bcrypt.hash(form.new_password)
        try await user.save(on: req.db)
        req.auth.logout(User.self)
        req.session.destroy()
        return req.redirect(to: "/login?msg=password_changed")
    }

    // POST /account/delete — hard delete, CASCADE wipes profile/engagements/captures
    func deleteAccount(req: Request) async throws -> Response {
        struct Form: Content { var password: String }
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(Form.self)
        guard (try? user.verify(password: form.password)) == true else {
            return req.redirect(to: "/account?err=delete_wrong_password")
        }
        try await user.delete(on: req.db)
        req.auth.logout(User.self)
        req.session.destroy()
        return req.redirect(to: "/login?msg=deleted")
    }

    // POST /logout
    func logout(req: Request) async -> Response {
        req.auth.logout(User.self)
        req.session.destroy()
        return req.redirect(to: "/login?msg=logged_out")
    }
}
