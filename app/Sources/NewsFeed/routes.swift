import Fluent
import Foundation
import SQLKit
import Vapor

func routes(_ app: Application) throws {
    // MARK: - Feed

    app.get { req async throws -> Response in
        let items = try await loadRankedFeed(on: req, limit: 25)
        let html = FeedView.render(items: items)
        return htmlResponse(html)
    }

    app.get("raw") { req async throws -> Response in
        let items = try await loadRankedFeed(on: req, limit: 50, orderByScore: false)
        let html = FeedView.render(items: items, title: "pulse / raw")
        return htmlResponse(html)
    }

    // MARK: - Capture

    app.get("capture") { req async -> Response in
        htmlResponse(CaptureView.renderForm(message: try? req.query.get(String.self, at: "msg")))
    }

    app.post("capture") { req async throws -> Response in
        struct Form: Content {
            var content: String?
            var source_hint: String?
        }
        let form = try req.content.decode(Form.self)
        guard let content = form.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return req.redirect(to: "/capture?msg=empty")
        }
        let hint = form.source_hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capture = Capture(content: content, sourceHint: hint?.isEmpty == true ? nil : hint)
        try await capture.save(on: req.db)

        if req.headers.contentType == .json || req.headers.first(name: .accept)?.contains("application/json") == true {
            return try await CaptureJSON(id: capture.id!, status: "saved").encodeResponse(for: req)
        }
        return req.redirect(to: "/capture?msg=saved")
    }

    // MARK: - Catch me up explainer

    app.get("catchup", ":id") { req async throws -> Response in
        guard let id = req.parameters.get("id", as: UUID.self),
              let item = try await FeedItem.query(on: req.db)
                .filter(\.$id == id)
                .with(\.$source)
                .first() else {
            throw Abort(.notFound)
        }

        let score = try await ItemScore.query(on: req.db)
            .filter(\.$item.$id == id)
            .first()

        let isHX = req.headers.first(name: "HX-Request") == "true"

        // If a cached explainer exists, show it. Otherwise show an iframe of
        // the original article with a banner — no on-click LLM work.
        if let cached = score?.catchupHTML, !cached.isEmpty {
            if isHX {
                return htmlResponse(CatchupView.renderFragment(item: item, score: score, explainerHTML: cached))
            } else {
                return htmlResponse(CatchupView.renderPage(item: item, score: score, explainerHTML: cached))
            }
        } else {
            if isHX {
                return htmlResponse(CatchupView.renderIframeFragment(item: item, score: score))
            } else {
                return htmlResponse(CatchupView.renderIframePage(item: item, score: score))
            }
        }
    }

    // MARK: - Misc

    // MARK: - Engagement (keep / skip)

    app.post("engage", ":id") { req async throws -> Response in
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        struct Form: Content { var event: String }
        let form = try req.content.decode(Form.self)
        let event = form.event.trimmingCharacters(in: .whitespaces)
        guard event == "keep" || event == "skip" else {
            throw Abort(.badRequest, reason: "event must be keep or skip")
        }
        try await Engagement(itemID: id, event: event).save(on: req.db)
        return Response(status: .noContent)
    }

    // MARK: - Misc

    app.get("hello") { _ async in "Hello, world!" }
    app.get("healthz") { _ async in "ok" }
}

// MARK: - Data loading

struct RankedRow: Decodable {
    let id: UUID
    let title: String
    let url: String
    let body: String?
    let published_at: Date?
    let fetched_at: Date?
    let source_name: String
    let source_lane: String
    let relevance_score: Int?
    let similarity: Float?
    let tldr: String?
    let why_this: String?
    let predicted_lane: String?
    let latest_engagement: String?  // "keep" | "skip" | nil
}

private func loadRankedFeed(on req: Request, limit: Int, orderByScore: Bool = true) async throws -> [RankedRow] {
    guard let sql = req.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }
    let orderClause = orderByScore
        ? "ORDER BY isc.relevance_score DESC NULLS LAST, isc.similarity DESC NULLS LAST, fi.published_at DESC NULLS LAST"
        : "ORDER BY fi.published_at DESC NULLS LAST, fi.fetched_at DESC"
    // Exclude items the user has skipped (by latest engagement). Kept and unvoted stay.
    let skipFilter = """
        (SELECT event FROM engagements eng2
           WHERE eng2.item_id = fi.id
           ORDER BY eng2.created_at DESC LIMIT 1) IS DISTINCT FROM 'skip'
        """
    return try await sql.raw("""
        SELECT fi.id AS id,
               fi.title AS title,
               fi.url AS url,
               fi.body AS body,
               fi.published_at AS published_at,
               fi.fetched_at AS fetched_at,
               fs.name AS source_name,
               fs.lane AS source_lane,
               isc.relevance_score AS relevance_score,
               isc.similarity AS similarity,
               isc.tldr AS tldr,
               isc.why_this AS why_this,
               isc.lane AS predicted_lane,
               (SELECT event FROM engagements eng
                  WHERE eng.item_id = fi.id
                  ORDER BY eng.created_at DESC LIMIT 1) AS latest_engagement
        FROM feed_items fi
        JOIN feed_sources fs ON fi.source_id = fs.id
        LEFT JOIN item_scores isc ON isc.item_id = fi.id
        WHERE \(unsafeRaw: skipFilter)
        \(unsafeRaw: orderClause)
        LIMIT \(bind: limit)
        """).all(decoding: RankedRow.self)
}

private func saveExplainerCache(
    itemID: UUID,
    existingScore: ItemScore?,
    html: String,
    on db: any Database
) async throws {
    guard let sql = db as? any SQLDatabase else { return }
    if let existing = existingScore, let scoreID = existing.id {
        try await sql.raw("""
            UPDATE item_scores
            SET catchup_html = \(bind: html), catchup_generated_at = NOW()
            WHERE id = \(bind: scoreID)
            """).run()
    } else {
        try await sql.raw("""
            INSERT INTO item_scores (id, item_id, catchup_html, catchup_generated_at, scored_at)
            VALUES (\(bind: UUID()), \(bind: itemID), \(bind: html), NOW(), NOW())
            ON CONFLICT (item_id) DO UPDATE SET
              catchup_html = EXCLUDED.catchup_html,
              catchup_generated_at = EXCLUDED.catchup_generated_at
            """).run()
    }
}

// MARK: - Explainer generation

private func generateExplainer(
    item: FeedItem,
    score: ItemScore?,
    ollama: OllamaClient
) async throws -> String {
    let body = (item.body.map(stripTagsExt) ?? "").prefix(2000)

    let system = """
    You are a neutral news explainer for someone smart who hasn't been following the story. \
    Present both sides' strongest case fairly. Never opine. Output clean HTML only, no markdown.
    """

    let user = """
    Item title: \(item.title)
    Source: \(item.source.name)
    Body: \(body)

    Write a catch-me-up explainer using ONLY these HTML tags: <h2>, <p>, <ul>, <li>, <strong>.
    Do not wrap in <html>, <body>, or <article>.

    Structure:
    <h2>Background</h2>
    <p>2-3 sentences of historical context. Who/what are the key players? When did this start?</p>

    <h2>What's new</h2>
    <p>1-2 sentences on what just happened that made this newsworthy now.</p>

    <h2>The two strongest takes</h2>
    <ul>
      <li><strong>One side says:</strong> steelman their case in 1-2 sentences</li>
      <li><strong>The other side says:</strong> steelman their case in 1-2 sentences</li>
    </ul>

    <h2>Conversation starter</h2>
    <p>One specific angle or question you could raise.</p>

    Rules:
    - If this is clearly a factual item with no controversy (weather, obituary, tech release), skip the "two strongest takes" section entirely.
    - Do not add any commentary outside the structure.
    """

    let html = try await ollama.chat(
        model: "llama3.2:3b",
        system: system,
        user: user,
        jsonMode: false,
        temperature: 0.3,
        numCtx: 4096
    )
    return html
}

// MARK: - View helpers

private func htmlResponse(_ html: String) -> Response {
    let response = Response(status: .ok, body: .init(string: html))
    response.headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
    return response
}

private struct CaptureJSON: Content {
    let id: UUID
    let status: String
}

// MARK: - Feed view

enum FeedView {
    static func render(items: [RankedRow], title: String = "pulse") -> String {
        let scoredCount = items.filter { $0.relevance_score != nil }.count
        let header = """
        <header>
          <h1>\(htmlEscape(title))</h1>
          <div class="subtitle">\(items.count) items · \(scoredCount) scored</div>
          <nav><a href="/">ranked</a> · <a href="/raw">raw</a> · <a href="/capture">+ capture</a></nav>
        </header>
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

    private static func renderArticle(_ r: RankedRow) -> String {
        let lane = r.predicted_lane ?? r.source_lane
        let source = htmlEscape(r.source_name)
        let title = htmlEscape(r.title)
        let time = relativeTime(r.published_at ?? r.fetched_at)

        let scoreBadge: String = {
            guard let s = r.relevance_score else { return "" }
            return "<span class=\"score score-\(s)\">\(s)</span>"
        }()

        let tldr: String = {
            guard let t = r.tldr, !t.isEmpty else { return "" }
            return "<p class=\"tldr\">\(htmlEscape(t))</p>"
        }()

        let whyThis: String = {
            guard let w = r.why_this, !w.isEmpty else { return "" }
            return "<div class=\"why\">🧭 \(htmlEscape(w))</div>"
        }()

        // Session-level engagement marker (persists in the list until reload removes skipped items)
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

enum CaptureView {
    static func renderForm(message: String?) -> String {
        let flash: String = {
            switch message {
            case "saved": return "<div class=\"flash ok\">Saved. We'll catch you up on this tomorrow.</div>"
            case "empty": return "<div class=\"flash err\">Can't save empty text.</div>"
            default: return ""
            }
        }()

        let body = """
        <header>
          <h1>capture</h1>
          <div class="subtitle">Heard something? Drop it here — tomorrow's brief will surface what's relevant.</div>
          <nav><a href="/">← feed</a></nav>
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
        """
        return page(title: "pulse / capture", body: body)
    }
}

enum CatchupView {
    // Standalone full-page view (direct navigation, e.g. shared link)
    static func renderPage(item: FeedItem, score: ItemScore?, explainerHTML: String) -> String {
        let body = """
        <main class="layout single">
          <div class="list">
            <header>
              <nav><a href="/">← feed</a></nav>
            </header>
            \(renderFragment(item: item, score: score, explainerHTML: explainerHTML, standalone: true))
          </div>
        </main>
        """
        return page(title: "pulse / catch up", body: body)
    }

    // Inner fragment for injection into #detail pane
    static func renderFragment(item: FeedItem, score: ItemScore?, explainerHTML: String, standalone: Bool = false) -> String {
        let lane = score?.predictedLane ?? item.source.lane
        let sourceBadge = "<span class=\"badge \(lane)\">\(htmlEscape(item.source.name))</span>"
        let scoreBadge: String = {
            guard let s = score?.relevanceScore else { return "" }
            return "<span class=\"score score-\(s)\">\(s)</span>"
        }()
        let closeButton = standalone
            ? ""
            : "<button class=\"close-btn\" aria-label=\"close\" onclick=\"closeDetail()\">×</button>"

        return """
        <section class="detail-panel">
          \(closeButton)
          <div class="detail-meta">
            \(scoreBadge) \(sourceBadge) <span class="time">\(relativeTime(item.publishedAt ?? item.fetchedAt))</span>
          </div>
          <h1 class="detail-title">\(htmlEscape(item.title))</h1>
          <p class="detail-original"><a href="\(htmlEscape(item.url))" target="_blank" rel="noopener">Read original →</a></p>
          <div class="catchup">
            \(explainerHTML)
          </div>
          \(engagementRow(itemID: item.id ?? UUID()))
        </section>
        """
    }

    // Uncached fallback: show an iframe of the original article with a banner.
    static func renderIframeFragment(item: FeedItem, score: ItemScore?, standalone: Bool = false) -> String {
        let lane = score?.predictedLane ?? item.source.lane
        let sourceBadge = "<span class=\"badge \(lane)\">\(htmlEscape(item.source.name))</span>"
        let scoreBadge: String = {
            guard let s = score?.relevanceScore else { return "" }
            return "<span class=\"score score-\(s)\">\(s)</span>"
        }()
        let closeButton = standalone
            ? ""
            : "<button class=\"close-btn\" aria-label=\"close\" onclick=\"closeDetail()\">×</button>"
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

    // Keep/skip buttons shared between explainer and iframe fragments.
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

    static func renderIframePage(item: FeedItem, score: ItemScore?) -> String {
        let body = """
        <main class="layout single">
          <div class="list">
            <header>
              <nav><a href="/">← feed</a></nav>
            </header>
            \(renderIframeFragment(item: item, score: score, standalone: true))
          </div>
        </main>
        """
        return page(title: "pulse / original", body: body)
    }
}

// MARK: - Shared HTML shell

private func page(title: String, body: String) -> String {
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>\(htmlEscape(title))</title>
      <style>\(css)</style>
      <script src="https://unpkg.com/htmx.org@2.0.4"></script>
    </head>
    <body>
      \(body)
      <script>\(inlineJS)</script>
    </body>
    </html>
    """
}

private let inlineJS = """
function openDetail() {
  document.body.classList.add('has-detail');
  document.querySelector('#detail')?.scrollTo({ top: 0, behavior: 'instant' });
}
function closeDetail() {
  document.body.classList.remove('has-detail');
  document.querySelectorAll('.card.selected').forEach(el => el.classList.remove('selected'));
  const d = document.getElementById('detail');
  if (d) d.innerHTML = '';
}
function escapeHTML(s) {
  return String(s || '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
// Debounced loading state: only show the "catching you up…" skeleton if the
// request takes longer than 200ms. Cached items (~10ms) swap cleanly with no
// flash; uncached cold clicks (~40s) see the skeleton appear at 200ms.
document.body.addEventListener('htmx:beforeRequest', (e) => {
  const el = e.detail?.elt;
  if (!el || !el.classList.contains('card')) return;
  // Select clicked card + open pane right away (purely visual, no content change)
  document.querySelectorAll('.card.selected').forEach(c => c.classList.remove('selected'));
  el.classList.add('selected');
  openDetail();
  // Arm a timer. If the response lands before this fires, we clear it in afterRequest.
  const title = el.querySelector('h2')?.textContent?.trim() || 'this item';
  const timer = setTimeout(() => {
    const detail = document.getElementById('detail');
    if (detail) {
      detail.innerHTML = `
        <section class="detail-panel loading-state">
          <button class="close-btn" aria-label="close" onclick="closeDetail()">×</button>
          <div class="loading-row">
            <div class="spinner-lg"></div>
            <div class="loading-meta">
              <div class="loading-label">catching you up on</div>
              <div class="loading-article">${escapeHTML(title)}</div>
            </div>
          </div>
          <div class="loading-note">Uncached items take ~40s on local Llama. Cached after.</div>
        </section>`;
    }
  }, 200);
  el._pulseLoadingTimer = timer;
});
document.body.addEventListener('htmx:afterRequest', (e) => {
  const el = e.detail?.elt;
  if (el && el._pulseLoadingTimer) {
    clearTimeout(el._pulseLoadingTimer);
    delete el._pulseLoadingTimer;
  }
  // Handle keep / skip button taps
  if (el && el.classList?.contains('engage') && e.detail?.successful) {
    const itemId = el.dataset.itemId;
    const isKeep = el.classList.contains('keep');
    const event = isKeep ? 'keep' : 'skip';
    // Mark the card in the list immediately
    document.querySelectorAll('.card[data-item-id="' + itemId + '"]').forEach(c => {
      c.classList.remove('kept', 'skipped');
      c.classList.add(event === 'keep' ? 'kept' : 'skipped');
    });
    // Button feedback and auto-close
    const row = el.closest('.engagement-row');
    if (row) row.classList.add('voted', 'voted-' + event);
    el.disabled = true;
    setTimeout(() => closeDetail(), 420);
  }
});
document.body.addEventListener('htmx:afterSwap', (e) => {
  if (e.target && e.target.id === 'detail') openDetail();
});
// Close on Escape
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && document.body.classList.contains('has-detail')) closeDetail();
});
"""

private let css = """
:root{--bg:#fafafa;--card:#fff;--text:#1a1a1a;--muted:#666;--accent:#0070f3;--border:#eee;--ok:#16a34a;--err:#dc2626;--selected:#e3f2fd}
@media(prefers-color-scheme:dark){:root{--bg:#0a0a0a;--card:#141414;--text:#f0f0f0;--muted:#888;--accent:#3291ff;--border:#222;--ok:#4ade80;--err:#f87171;--selected:#0a1a2e}}
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{font:16px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;background:var(--bg);color:var(--text)}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}

/* layout */
main.layout{display:block;max-width:720px;margin:0 auto;padding:24px 16px}
main.layout.single{max-width:720px}
.list{width:100%}
.detail{display:none}

/* wide screens: two-column when detail is open */
@media(min-width:900px){
  body.has-detail main.layout{max-width:1440px;display:grid;grid-template-columns:minmax(360px,1fr) minmax(480px,1.4fr);gap:40px;align-items:start}
  body.has-detail .list{max-width:none}
  body.has-detail .detail{display:block;position:sticky;top:24px;max-height:calc(100vh - 48px);overflow-y:auto;padding:8px 4px 24px 4px;animation:slideInRight 0.2s ease-out}
}
@keyframes slideInRight{from{opacity:0;transform:translateX(12px)}to{opacity:1;transform:translateX(0)}}

/* mobile: detail takes over */
@media(max-width:899px){
  body.has-detail .detail{display:block;position:fixed;inset:0;background:var(--bg);overflow-y:auto;padding:24px 16px;z-index:10;animation:slideInUp 0.2s ease-out}
  body.has-detail .list{visibility:hidden}
}
@keyframes slideInUp{from{opacity:0;transform:translateY(16px)}to{opacity:1;transform:translateY(0)}}

/* header */
header{margin-bottom:20px;padding-bottom:10px;border-bottom:1px solid var(--border)}
h1{font-size:28px;margin-bottom:4px;letter-spacing:-0.02em}
.subtitle{color:var(--muted);font-size:13px}
nav{margin-top:6px;font-size:13px;color:var(--muted)}

/* cards */
.card{padding:14px 12px;border-bottom:1px solid var(--border);cursor:pointer;transition:background 0.12s}
.card:hover{background:var(--card)}
.card.selected{background:var(--selected);border-radius:6px;border-bottom-color:transparent}
.meta{display:flex;gap:8px;align-items:center;margin-bottom:6px;font-size:12px;color:var(--muted);flex-wrap:wrap}
.badge{padding:2px 8px;border-radius:4px;font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:0.5px}
.badge.tech{background:#e3f2fd;color:#0d47a1}
.badge.conversation{background:#fff3e0;color:#e65100}
.score{display:inline-block;min-width:26px;text-align:center;padding:2px 6px;border-radius:4px;font-size:11px;font-weight:700;background:#eee;color:#333}
.score-1,.score-2,.score-3{background:#f5f5f5;color:#888}
.score-4,.score-5{background:#e8f5e9;color:#1b5e20}
.score-6,.score-7{background:#c8e6c9;color:#1b5e20}
.score-8,.score-9,.score-10{background:#2e7d32;color:#fff}
@media(prefers-color-scheme:dark){
  .badge.tech{background:#0a1a2e;color:#60a5fa}
  .badge.conversation{background:#2a1a0a;color:#fbbf24}
  .score{background:#222;color:#ccc}
  .score-1,.score-2,.score-3{background:#1a1a1a;color:#555}
  .score-4,.score-5{background:#1a2a1a;color:#86efac}
  .score-6,.score-7{background:#1a3a1a;color:#bbf7d0}
  .score-8,.score-9,.score-10{background:#14532d;color:#fff}
}
.card h2{font-size:16px;font-weight:600;margin-bottom:6px;line-height:1.35;color:var(--text)}
.tldr{font-size:14px;color:var(--text);margin:6px 0;line-height:1.5}
.why{font-size:12px;color:var(--muted);margin:4px 0 0 0;font-style:italic}

/* card engagement state — kept = subtle green tick; skipped = faded */
.card.kept{position:relative}
.card.kept::after{content:"✓ kept";position:absolute;top:14px;right:10px;font-size:10px;font-weight:700;color:#16a34a;letter-spacing:0.04em;text-transform:uppercase}
.card.skipped{opacity:0.5}
.card.skipped::after{content:"skipped";position:absolute;top:14px;right:10px;font-size:10px;font-weight:600;color:var(--muted);letter-spacing:0.04em;text-transform:uppercase}
@media(prefers-color-scheme:dark){.card.kept::after{color:#4ade80}}

/* detail panel */
.detail-panel{position:relative;padding-right:40px}
.close-btn{position:absolute;top:0;right:0;width:32px;height:32px;border:none;background:transparent;color:var(--muted);font-size:24px;cursor:pointer;border-radius:4px;display:flex;align-items:center;justify-content:center}
.close-btn:hover{background:var(--border);color:var(--text)}
.detail-meta{display:flex;gap:10px;align-items:center;margin-bottom:12px;font-size:13px;color:var(--muted);flex-wrap:wrap}
.detail-title{font-size:22px;margin-bottom:8px;letter-spacing:-0.01em}
.detail-original{font-size:14px;margin-bottom:20px}
.catchup h2{font-size:13px;margin-top:20px;margin-bottom:6px;color:var(--muted);text-transform:uppercase;letter-spacing:0.05em;font-weight:700}
.catchup h2:first-child{margin-top:0}
.catchup p{margin:6px 0 12px;line-height:1.65;font-size:15px}
.catchup ul{margin:6px 0 12px 20px}
.catchup li{margin:6px 0;line-height:1.6;font-size:15px}

/* iframe mode (uncached) */
.iframe-mode{display:flex;flex-direction:column}
.banner-uncached{background:#fff7ed;border:1px solid #fdba74;color:#9a3412;padding:10px 12px;border-radius:6px;margin:8px 0 12px;font-size:13px;line-height:1.5}
@media(prefers-color-scheme:dark){.banner-uncached{background:#2a1a0a;border-color:#9a3412;color:#fbbf24}}
.muted{color:var(--muted);font-size:12px}
.iframe-wrap{margin-top:8px;border:1px solid var(--border);border-radius:6px;overflow:hidden;background:#fff;flex:1;min-height:480px}
.iframe-wrap iframe{width:100%;height:100%;min-height:480px;border:none;display:block}
@media(min-width:900px){
  body.has-detail .detail .iframe-wrap{min-height:calc(100vh - 260px)}
  body.has-detail .detail .iframe-wrap iframe{min-height:calc(100vh - 260px)}
}

/* keep/skip buttons at bottom of detail */
.engagement-row{display:flex;gap:12px;margin-top:24px;padding-top:16px;border-top:1px solid var(--border)}
.engage{flex:1;padding:12px 16px;font:inherit;font-size:14px;font-weight:600;border:1px solid var(--border);border-radius:8px;background:var(--card);color:var(--text);cursor:pointer;transition:all 0.15s ease;text-transform:lowercase;letter-spacing:0.02em}
.engage.keep:hover{background:#dcfce7;color:#14532d;border-color:#16a34a}
.engage.skip:hover{background:#fef2f2;color:#991b1b;border-color:#dc2626}
@media(prefers-color-scheme:dark){
  .engage.keep:hover{background:#052e16;color:#86efac;border-color:#16a34a}
  .engage.skip:hover{background:#2a0a0a;color:#fca5a5;border-color:#dc2626}
}
.engage:disabled{cursor:default;transform:scale(0.96);opacity:0.85}
.engagement-row.voted-keep .engage.keep{background:#16a34a;color:#fff;border-color:#16a34a}
.engagement-row.voted-skip .engage.skip{background:#dc2626;color:#fff;border-color:#dc2626}
.engagement-row.voted .engage:not(:disabled){opacity:0.35}

/* loading skeleton inside the detail pane */
.loading-state{min-height:240px;padding:8px 40px 24px 4px}
.loading-row{display:flex;gap:18px;align-items:center;padding:24px 0}
.spinner-lg{width:36px;height:36px;border:3px solid var(--border);border-top-color:var(--accent);border-radius:50%;animation:spin 0.7s linear infinite;flex-shrink:0}
.loading-meta{min-width:0}
.loading-label{font-size:11px;text-transform:uppercase;letter-spacing:0.08em;color:var(--muted);font-weight:700;margin-bottom:6px}
.loading-article{font-size:18px;font-weight:600;color:var(--text);line-height:1.35}
.loading-note{font-size:12px;color:var(--muted);font-style:italic;margin-top:8px;padding-top:12px;border-top:1px solid var(--border)}

/* capture form */
.capture-form{display:flex;flex-direction:column;gap:12px;margin-top:16px;max-width:560px}
.capture-form label{display:flex;flex-direction:column;gap:4px;font-size:13px;color:var(--muted)}
.capture-form textarea,.capture-form input{font:inherit;padding:10px;border:1px solid var(--border);border-radius:6px;background:var(--card);color:var(--text);resize:vertical}
.capture-form button{padding:10px 16px;font:inherit;font-weight:600;background:var(--accent);color:#fff;border:none;border-radius:6px;cursor:pointer;max-width:200px}
.flash{padding:10px 12px;border-radius:6px;margin:12px 0;font-size:14px}
.flash.ok{background:#e8f5e9;color:var(--ok);border:1px solid var(--ok)}
.flash.err{background:#fef2f2;color:var(--err);border:1px solid var(--err)}

@keyframes spin{to{transform:rotate(360deg)}}
"""

// MARK: - helpers (file-private)

private func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&#39;")
}

private func stripTagsExt(_ s: String) -> String {
    let noTags = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    return noTags
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func relativeTime(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let elapsed = Date().timeIntervalSince(date)
    if elapsed < 60 { return "just now" }
    if elapsed < 3600 { return "\(Int(elapsed/60))m ago" }
    if elapsed < 86400 { return "\(Int(elapsed/3600))h ago" }
    if elapsed < 86400*30 { return "\(Int(elapsed/86400))d ago" }
    return "\(Int(elapsed/(86400*30)))mo ago"
}
