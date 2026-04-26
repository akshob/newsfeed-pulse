import Foundation

enum OnboardingView {
    /// Renders the onboarding form. Checkboxes show ONLY the user's
    /// explicit selection — nothing the LLM inferred from freeform ticks
    /// a checkbox. Inferred categories are shown as a separate readonly
    /// tag row below so the user can see what the system picked up
    /// without it pretending to be their own choice.
    static func render(
        email: String,
        currentCategories: [String],
        currentInferredCategories: [String],
        currentFreeform: String,
        message: String?,
        error: String?
    ) -> String {
        let flash: String = {
            if error == "empty" { return "<div class=\"flash err\">Add at least one category or a sentence of interests.</div>" }
            return ""
        }()

        let selected = Set(currentCategories)
        let categoryItems = interestCategories.map { cat -> String in
            let isChecked = selected.contains(cat.key) ? " checked" : ""
            return "            <label><input type=\"checkbox\" name=\"categories\" value=\"\(cat.key)\"\(isChecked)> \(cat.label)</label>"
        }.joined(separator: "\n")

        // Inferred row: only render if the LLM actually picked something up.
        // Tags map back to their human label; checkboxes already labelled.
        let inferredBlock: String = {
            guard !currentInferredCategories.isEmpty else { return "" }
            let labelByKey = Dictionary(uniqueKeysWithValues: interestCategories.map { ($0.key, $0.label) })
            let chips = currentInferredCategories.compactMap { labelByKey[$0] }.map { label in
                "<span class=\"tag tag-inferred\">\(htmlEscape(label))</span>"
            }.joined(separator: " ")
            return """
            <div class="inferred-row">
              <div class="inferred-label">Inferred from your description</div>
              <div class="inferred-chips">\(chips)</div>
              <div class="inferred-hint">These came from the text below — to remove one, edit the description and resubmit.</div>
            </div>
            """
        }()

        let body = """
        <main class="layout">
          <div class="list">
            <header>
              <div class="header-row">
                <div>
                  <h1>What's in your feed?</h1>
                  <div class="subtitle">Tick the categories that interest you — specifics in the blurb below are best. You can change this later from your account page.</div>
                </div>
                \(avatarHTML(for: email))
              </div>
              <nav class="btn-row">
                <a class="btn-link" href="/">← feed</a>
              </nav>
            </header>
            \(flash)
            <form method="POST" action="/onboarding" class="onboard-form">
              <fieldset>
                <legend>Categories</legend>
        \(categoryItems)
              </fieldset>
              <label>Tell me more — what to stay on, what to skip
                <textarea name="freeform" rows="6" placeholder="Be specific. 'AI/LLM research, developer tooling, help me catch up on political stories where I lack context. Skip: tech company PR, cycle-of-the-day political noise.'">\(htmlEscape(currentFreeform))</textarea>
              </label>
              \(inferredBlock)
              <button type="submit">Save and continue</button>
            </form>
          </div>
        </main>
        """
        return page(title: "pulse / interests", body: body)
    }
}
