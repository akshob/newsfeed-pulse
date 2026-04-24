import Foundation

enum LoginView {
    static func render(message: String?, error: String?) -> String {
        let msg: String = {
            switch message {
            case "logged_out": return "<div class=\"flash ok\">Logged out.</div>"
            case "password_changed": return "<div class=\"flash ok\">Password updated. Please log in with your new password.</div>"
            case "deleted": return "<div class=\"flash ok\">Your account was deleted.</div>"
            default: return ""
            }
        }()
        let err: String = {
            switch error {
            case "invalid": return "<div class=\"flash err\">Wrong email or password.</div>"
            default: return ""
            }
        }()
        let body = """
        <div class="auth-wrap">
          <header><h1>pulse</h1><div class="subtitle">Sign in</div></header>
          \(msg)\(err)
          <form method="POST" action="/login" class="auth-form">
            <label>Email <input type="email" name="email" required autofocus autocomplete="username"></label>
            <label>Password <input type="password" name="password" required autocomplete="current-password"></label>
            <button type="submit" class="btn-small">Log in</button>
          </form>
          <p class="auth-footer">Have an invite? <a href="/signup">Sign up</a></p>
        </div>
        """
        return page(title: "pulse / login", body: body)
    }
}
