import Foundation

enum CatchupView {
    static func renderPage(item: FeedItem, score: ItemScore?, explainerHTML: String) -> String {
        let body = """
        <main class="layout single">
          <div class="list">
            <header><nav class="btn-row"><a class="btn-link" href="/">← feed</a></nav></header>
            \(renderFragment(item: item, score: score, explainerHTML: explainerHTML, standalone: true))
          </div>
        </main>
        """
        return page(title: "pulse / catch up", body: body)
    }

    static func renderFragment(item: FeedItem, score: ItemScore?, explainerHTML: String, standalone: Bool = false) -> String {
        let lane = score?.predictedLane ?? item.source.lane
        let sourceBadge = "<span class=\"badge \(lane)\">\(htmlEscape(item.source.name))</span>"
        let scoreBadge: String = score?.relevanceScore.map { "<span class=\"score score-\($0)\">\($0)</span>" } ?? ""
        let closeButton = standalone ? "" : "<button class=\"close-btn\" aria-label=\"close\" onclick=\"closeDetail()\">×</button>"
        return """
        <section class="detail-panel">
          \(closeButton)
          <div class="detail-meta">
            \(scoreBadge) \(sourceBadge) <span class="time">\(relativeTime(item.publishedAt ?? item.fetchedAt))</span>
          </div>
          <h1 class="detail-title">\(htmlEscape(item.title))</h1>
          <p class="detail-original"><a href="\(htmlEscape(item.url))" target="_blank" rel="noopener">Read original →</a></p>
          <div class="catchup">\(explainerHTML)</div>
          \(engagementRow(itemID: item.id ?? UUID()))
        </section>
        """
    }

    static func renderIframeFragment(item: FeedItem, score: ItemScore?, standalone: Bool = false) -> String {
        let lane = score?.predictedLane ?? item.source.lane
        let sourceBadge = "<span class=\"badge \(lane)\">\(htmlEscape(item.source.name))</span>"
        let scoreBadge: String = score?.relevanceScore.map { "<span class=\"score score-\($0)\">\($0)</span>" } ?? ""
        let closeButton = standalone ? "" : "<button class=\"close-btn\" aria-label=\"close\" onclick=\"closeDetail()\">×</button>"
        let url = htmlEscape(item.url)
        return """
        <section class="detail-panel iframe-mode">
          \(closeButton)
          <div class="detail-meta">
            \(scoreBadge) \(sourceBadge) <span class="time">\(relativeTime(item.publishedAt ?? item.fetchedAt))</span>
          </div>
          <h1 class="detail-title">\(htmlEscape(item.title))</h1>
          <div class="banner-uncached">
            The catch-me-up view isn't ready for this one yet — showing the original article below. The explainer generates in the background during the hourly pipeline.
          </div>
          <p class="detail-original"><a href="\(url)" target="_blank" rel="noopener">Open original in new tab ↗</a> <span class="muted">(use this if the embed below is blocked by the site)</span></p>
          <div class="iframe-wrap">
            <iframe src="\(url)" referrerpolicy="no-referrer" sandbox="allow-same-origin allow-scripts allow-popups allow-forms allow-downloads" loading="lazy" title="\(htmlEscape(item.title))"></iframe>
          </div>
          \(engagementRow(itemID: item.id ?? UUID()))
        </section>
        """
    }

    static func renderIframePage(item: FeedItem, score: ItemScore?) -> String {
        let body = """
        <main class="layout single">
          <div class="list">
            <header><nav class="btn-row"><a class="btn-link" href="/">← feed</a></nav></header>
            \(renderIframeFragment(item: item, score: score, standalone: true))
          </div>
        </main>
        """
        return page(title: "pulse / original", body: body)
    }

    static func engagementRow(itemID: UUID) -> String {
        let id = itemID.uuidString
        return """
        <div class="engagement-row">
          <button class="engage keep" data-item-id="\(id)"
                  hx-post="/engage/\(id)" hx-vals='{"event":"keep"}' hx-swap="none">keep</button>
          <button class="engage skip" data-item-id="\(id)"
                  hx-post="/engage/\(id)" hx-vals='{"event":"skip"}' hx-swap="none">skip</button>
        </div>
        """
    }
}
