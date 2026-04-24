import Foundation

enum FeedView {
    static func render(items: [RankedRow], userEmail: String? = nil, title: String = "pulse", message: String? = nil) -> String {
        let scoredCount = items.filter { $0.relevance_score != nil }.count
        let flash: String = {
            switch message {
            case "interests_saved": return "<div class=\"flash ok\">Interests saved.</div>"
            default: return ""
            }
        }()
        let header = """
        <header>
          <h1>\(htmlEscape(title))</h1>
          <div class="subtitle">\(items.count) items · \(scoredCount) scored</div>
          <nav>
            <a href="/">ranked</a> · <a href="/raw">raw</a> · <a href="/capture">+ capture</a>
            <span class="user">· <a href="/account">\(htmlEscape(userEmail ?? ""))</a></span>
          </nav>
        </header>
        \(flash)
        """
        let articles = items.map(renderArticle).joined(separator: "\n")
        let body = """
        <main class="layout">
          <div class="list">
            \(header)
            \(articles)
          </div>
          <aside class="detail" id="detail" aria-live="polite"></aside>
        </main>
        """
        return page(title: title, body: body)
    }

    static func renderArticle(_ r: RankedRow) -> String {
        let lane = r.predicted_lane ?? r.source_lane
        let source = htmlEscape(r.source_name)
        let title = htmlEscape(r.title)
        let time = relativeTime(r.published_at ?? r.fetched_at)
        let scoreBadge: String = r.relevance_score.map { "<span class=\"score score-\($0)\">\($0)</span>" } ?? ""
        let tldr: String = r.tldr.flatMap { $0.isEmpty ? nil : "<p class=\"tldr\">\(htmlEscape($0))</p>" } ?? ""
        let whyThis: String = r.why_this.flatMap { $0.isEmpty ? nil : "<div class=\"why\">🧭 \(htmlEscape($0))</div>" } ?? ""
        let engageClass: String = {
            switch r.latest_engagement {
            case "keep": return " kept"
            case "skip": return " skipped"
            default: return ""
            }
        }()
        return """
        <article class="card lane-\(lane)\(engageClass)"
                 data-item-id="\(r.id.uuidString)"
                 hx-get="/catchup/\(r.id.uuidString)"
                 hx-target="#detail"
                 hx-swap="innerHTML">
          <div class="meta">
            \(scoreBadge)
            <span class="badge \(lane)">\(source)</span>
            <span class="time">\(time)</span>
          </div>
          <h2>\(title)</h2>
          \(tldr)
          \(whyThis)
        </article>
        """
    }
}
