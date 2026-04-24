import Foundation

enum AccountView {
    static func render(email: String, message: String?, error: String?) -> String {
        let flash: String = {
            switch error {
            case "current_wrong": return "<div class=\"flash err\">Current password is wrong.</div>"
            case "mismatch": return "<div class=\"flash err\">New passwords don't match.</div>"
            case "short": return "<div class=\"flash err\">Password must be at least 8 characters.</div>"
            case "delete_wrong_password": return "<div class=\"flash err\">Wrong password. Account not deleted.</div>"
            default: return ""
            }
        }()
        let body = """
        <main class="layout">
          <div class="list">
            <header>
              <div class="header-row">
                <div>
                  <h1>Account</h1>
                  <div class="subtitle">Signed in as <strong>\(htmlEscape(email))</strong></div>
                </div>
                <span class="avatar-link avatar-lg" aria-label="your avatar"><span class="avatar">\(identiconSVG(for: email, size: 64))</span></span>
              </div>
              <nav class="btn-row">
                <a class="btn-link" href="/">← feed</a>
              </nav>
            </header>
            \(flash)

            <section class="account-section">
              <h2>Your interests</h2>
              <p class="muted">Edit what the feed knows about you.</p>
              <p><a class="btn-link" href="/onboarding">Update interests →</a></p>
            </section>

            <section class="account-section">
              <h2>Change password</h2>
              <form method="POST" action="/account/password" class="auth-form">
                <label>Current password <input type="password" name="current_password" required autocomplete="current-password"></label>
                <label>New password (min 8 chars) <input type="password" name="new_password" required minlength="8" autocomplete="new-password"></label>
                <label>Confirm new password <input type="password" name="confirm_password" required minlength="8" autocomplete="new-password"></label>
                <button type="submit">Change password</button>
              </form>
              <p class="muted">You'll be logged out and asked to sign in again after changing.</p>
            </section>

            <section class="account-section">
              <h2>Sign out</h2>
              <form method="POST" action="/logout" class="auth-form">
                <button type="submit">Log out</button>
              </form>
            </section>

            <section class="account-section danger-zone">
              <h2>Delete account</h2>
              <p><strong>This cannot be undone.</strong> All your interests, captures, and engagement history will be permanently deleted.</p>
              <form method="POST" action="/account/delete" class="auth-form"
                    onsubmit="return confirm('Delete your account? This cannot be undone.');">
                <label>Enter your password to confirm <input type="password" name="password" required autocomplete="current-password"></label>
                <button type="submit" class="danger">Delete my account</button>
              </form>
            </section>
          </div>
        </main>
        """
        return page(title: "pulse / account", body: body)
    }
}
