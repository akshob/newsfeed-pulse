import Foundation

enum OnboardingView {
    static func render(email: String, currentBlurb: String?, message: String?, error: String?) -> String {
        let flash: String = {
            if error == "empty" { return "<div class=\"flash err\">Add at least one category or a sentence of interests.</div>" }
            return ""
        }()
        let blurbText = currentBlurb ?? ""
        let lowered = blurbText.lowercased()
        let categoryItems = interestCategories.map { cat -> String in
            let isChecked = lowered.contains(cat.key) ? " checked" : ""
            return "            <label><input type=\"checkbox\" name=\"categories\" value=\"\(cat.key)\"\(isChecked)> \(cat.label)</label>"
        }.joined(separator: "\n")

        let body = """
        <main class="layout">
          <div class="list">
            <header>
              <h1>What's in your feed?</h1>
              <div class="subtitle">Tick the categories that interest you — specifics in the blurb below are best. You can change this later from your account page.</div>
              <nav><a href="/">← feed</a> · <a href="/account">\(htmlEscape(email))</a></nav>
            </header>
            \(flash)
            <form method="POST" action="/onboarding" class="onboard-form">
              <fieldset>
                <legend>Categories</legend>
        \(categoryItems)
              </fieldset>
              <label>Tell me more — what to stay on, what to skip
                <textarea name="blurb" rows="6" placeholder="Be specific. 'AI/LLM research, developer tooling, help me catch up on political stories where I lack context. Skip: tech company PR, cycle-of-the-day political noise.'">\(htmlEscape(blurbText))</textarea>
              </label>
              <button type="submit">Save and continue</button>
            </form>
          </div>
        </main>
        """
        return page(title: "pulse / interests", body: body)
    }
}
