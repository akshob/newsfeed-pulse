import Foundation

enum SignupView {
    static func render(prefilledCode: String, error: String?) -> String {
        let err: String = {
            switch error {
            case "invalid_code": return "<div class=\"flash err\">That invite code is invalid or has been used.</div>"
            case "bad_email": return "<div class=\"flash err\">That email doesn't look right.</div>"
            case "short_password": return "<div class=\"flash err\">Password must be at least 8 characters.</div>"
            case "mismatch": return "<div class=\"flash err\">Passwords don't match.</div>"
            case "email_taken": return "<div class=\"flash err\">That email is already registered — try logging in.</div>"
            default: return ""
            }
        }()
        let body = """
        <div class="auth-wrap">
          <header><h1>pulse</h1><div class="subtitle">Create your account</div></header>
          \(err)
          <form method="POST" action="/signup" class="auth-form">
            <label>Invite code <input type="text" name="code" required value="\(htmlEscape(prefilledCode))" autocomplete="off"></label>
            <label>Email (this is your username) <input type="email" name="email" required autocomplete="username"></label>
            <label>Password (min 8 chars) <input type="password" name="password" required minlength="8" autocomplete="new-password"></label>
            <label>Confirm password <input type="password" name="confirm_password" required minlength="8" autocomplete="new-password"></label>
            <button type="submit">Create account</button>
          </form>
          <p class="auth-footer">Already have an account? <a href="/login">Log in</a></p>
        </div>
        """
        return page(title: "pulse / sign up", body: body)
    }
}
