import Foundation

enum CaptureView {
    static func renderForm(userEmail: String?, message: String?) -> String {
        let flash: String = {
            switch message {
            case "saved": return "<div class=\"flash ok\">Saved. We'll catch you up on this tomorrow.</div>"
            case "empty": return "<div class=\"flash err\">Can't save empty text.</div>"
            default: return ""
            }
        }()
        let body = """
        <main class="layout">
          <div class="list">
            <header>
              <div class="header-row">
                <div>
                  <h1>capture</h1>
                  <div class="subtitle">Heard something? Drop it here — tomorrow's brief will surface what's relevant.</div>
                </div>
                \(avatarHTML(for: userEmail))
              </div>
              <nav class="btn-row">
                <a class="btn-link" href="/">← feed</a>
              </nav>
            </header>
            \(flash)
            <form method="POST" action="/capture" class="capture-form">
              <label>What did you hear?
                <textarea name="content" rows="4" placeholder="e.g. 'wife mentioned something about the supreme court ruling'" required autofocus></textarea>
              </label>
              <label>Source hint (optional)
                <input name="source_hint" placeholder="wife · coworker · podcast · X">
              </label>
              <button type="submit">Capture</button>
            </form>
          </div>
        </main>
        """
        return page(title: "pulse / capture", body: body)
    }
}
