import Fluent
import Foundation
import SQLKit
import Vapor

func routes(_ app: Application) throws {
    // ===== Public routes =====

    app.get("login") { req async throws -> Response in
        if req.auth.has(User.self) { return req.redirect(to: "/") }
        let msg = try? req.query.get(String.self, at: "msg")
        let err = try? req.query.get(String.self, at: "err")
        return htmlResponse(LoginView.render(message: msg, error: err))
    }

    app.post("login") { req async throws -> Response in
        struct Form: Content { var email: String; var password: String }
        let form = try req.content.decode(Form.self)
        let email = form.email.lowercased().trimmingCharacters(in: .whitespaces)
        guard let user = try await User.query(on: req.db).filter(\.$email == email).first(),
              (try? user.verify(password: form.password)) == true else {
            return req.redirect(to: "/login?err=invalid")
        }
        req.auth.login(user)
        req.session.authenticate(user)
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == user.requireID()).first()
        return req.redirect(to: profile == nil ? "/onboarding" : "/")
    }

    app.get("signup") { req async throws -> Response in
        if req.auth.has(User.self) { return req.redirect(to: "/") }
        let code = (try? req.query.get(String.self, at: "code")) ?? ""
        let err = try? req.query.get(String.self, at: "err")
        return htmlResponse(SignupView.render(prefilledCode: code, error: err))
    }

    app.post("signup") { req async throws -> Response in
        struct Form: Content {
            var code: String
            var email: String
            var password: String
            var confirm_password: String
        }
        let form = try req.content.decode(Form.self)
        let code = form.code.lowercased().trimmingCharacters(in: .whitespaces)
        let email = form.email.lowercased().trimmingCharacters(in: .whitespaces)

        func bounce(_ err: String) -> Response {
            req.redirect(to: "/signup?err=\(err)&code=\(code)")
        }

        guard let invite = try await Invite.query(on: req.db)
            .filter(\.$code == code)
            .filter(\.$usedAt == nil)
            .first() else { return bounce("invalid_code") }
        guard email.contains("@"), email.count >= 3 else { return bounce("bad_email") }
        guard form.password.count >= 8 else { return bounce("short_password") }
        guard form.password == form.confirm_password else { return bounce("mismatch") }
        if try await User.query(on: req.db).filter(\.$email == email).first() != nil {
            return bounce("email_taken")
        }

        let user = User(email: email, passwordHash: try Bcrypt.hash(form.password))
        try await user.save(on: req.db)

        invite.usedAt = Date()
        invite.$usedBy.id = try user.requireID()
        try await invite.save(on: req.db)

        req.auth.login(user)
        req.session.authenticate(user)
        return req.redirect(to: "/onboarding")
    }

    app.get("hello") { _ async in "Hello, world!" }
    app.get("healthz") { _ async in "ok" }

    // ===== Protected routes =====

    let protected = app.grouped(AuthRedirectMiddleware(loginPath: "/login"))

    protected.post("logout") { req async -> Response in
        req.auth.logout(User.self)
        req.session.destroy()
        return req.redirect(to: "/login?msg=logged_out")
    }

    // Onboarding
    protected.get("onboarding") { req async throws -> Response in
        let user = try req.auth.require(User.self)
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == user.requireID()).first()
        return htmlResponse(OnboardingView.render(
            email: user.email,
            currentBlurb: profile?.blurb,
            message: try? req.query.get(String.self, at: "msg"),
            error: try? req.query.get(String.self, at: "err")
        ))
    }

    protected.post("onboarding") { req async throws -> Response in
        struct Form: Content {
            var categories: [String]?
            var blurb: String?
        }
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(Form.self)
        let blurb = composeBlurb(categories: form.categories ?? [], freeform: form.blurb ?? "")
        guard !blurb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return req.redirect(to: "/onboarding?err=empty")
        }
        try await upsertUserProfile(userID: try user.requireID(), blurb: blurb, on: req)
        return req.redirect(to: "/?msg=interests_saved")
    }

    // Account
    protected.get("account") { req async throws -> Response in
        let user = try req.auth.require(User.self)
        return htmlResponse(AccountView.render(
            email: user.email,
            message: try? req.query.get(String.self, at: "msg"),
            error: try? req.query.get(String.self, at: "err")
        ))
    }

    protected.post("account", "password") { req async throws -> Response in
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

    protected.post("account", "delete") { req async throws -> Response in
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

    // Feed
    protected.get { req async throws -> Response in
        let user = try req.auth.require(User.self)
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == user.requireID()).first()
        if profile == nil { return req.redirect(to: "/onboarding") }

        let items = try await loadRankedFeed(on: req, limit: 25)
        return htmlResponse(FeedView.render(
            items: items,
            userEmail: user.email,
            message: try? req.query.get(String.self, at: "msg")
        ))
    }

    protected.get("raw") { req async throws -> Response in
        let user = try req.auth.require(User.self)
        let items = try await loadRankedFeed(on: req, limit: 50, orderByScore: false)
        return htmlResponse(FeedView.render(items: items, userEmail: user.email, title: "pulse / raw"))
    }

    // Capture
    protected.get("capture") { req async throws -> Response in
        let user = try req.auth.require(User.self)
        return htmlResponse(CaptureView.renderForm(
            userEmail: user.email,
            message: try? req.query.get(String.self, at: "msg")
        ))
    }

    protected.post("capture") { req async throws -> Response in
        struct Form: Content {
            var content: String?
            var source_hint: String?
        }
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(Form.self)
        guard let content = form.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return req.redirect(to: "/capture?msg=empty")
        }
        let hint = form.source_hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capture = Capture(
            userID: try user.requireID(),
            content: content,
            sourceHint: hint?.isEmpty == true ? nil : hint
        )
        try await capture.save(on: req.db)
        if req.headers.contentType == .json ||
           req.headers.first(name: .accept)?.contains("application/json") == true {
            return try await CaptureJSON(id: capture.id!, status: "saved").encodeResponse(for: req)
        }
        return req.redirect(to: "/capture?msg=saved")
    }

    // Catchup
    protected.get("catchup", ":id") { req async throws -> Response in
        guard let id = req.parameters.get("id", as: UUID.self),
              let item = try await FeedItem.query(on: req.db)
                .filter(\.$id == id)
                .with(\.$source)
                .first() else {
            throw Abort(.notFound)
        }
        let score = try await ItemScore.query(on: req.db)
            .filter(\.$item.$id == id).first()
        let isHX = req.headers.first(name: "HX-Request") == "true"

        if let cached = score?.catchupHTML, !cached.isEmpty {
            return htmlResponse(isHX
                ? CatchupView.renderFragment(item: item, score: score, explainerHTML: cached)
                : CatchupView.renderPage(item: item, score: score, explainerHTML: cached))
        } else {
            return htmlResponse(isHX
                ? CatchupView.renderIframeFragment(item: item, score: score)
                : CatchupView.renderIframePage(item: item, score: score))
        }
    }

    // Engagement (keep / skip)
    protected.post("engage", ":id") { req async throws -> Response in
        guard let itemID = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        struct Form: Content { var event: String }
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(Form.self)
        let event = form.event.trimmingCharacters(in: .whitespaces)
        guard event == "keep" || event == "skip" else {
            throw Abort(.badRequest, reason: "event must be keep or skip")
        }
        let sim = try await ItemScore.query(on: req.db)
            .filter(\.$item.$id == itemID).first()?.similarity
        try await Engagement(
            itemID: itemID,
            userID: try user.requireID(),
            event: event,
            similarityAtVote: sim
        ).save(on: req.db)
        return Response(status: .noContent)
    }
}

// ===== Middleware =====

struct AuthRedirectMiddleware: AsyncMiddleware {
    let loginPath: String
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if request.auth.has(User.self) { return try await next.respond(to: request) }
        if request.headers.first(name: "HX-Request") == "true" {
            let resp = Response(status: .unauthorized)
            resp.headers.replaceOrAdd(name: "HX-Redirect", value: loginPath)
            return resp
        }
        return request.redirect(to: loginPath)
    }
}

// ===== Data loading =====

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
    let latest_engagement: String?
}

private func loadRankedFeed(on req: Request, limit: Int, orderByScore: Bool = true) async throws -> [RankedRow] {
    guard let sql = req.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }
    let orderClause = orderByScore
        ? "ORDER BY isc.relevance_score DESC NULLS LAST, isc.similarity DESC NULLS LAST, fi.published_at DESC NULLS LAST"
        : "ORDER BY fi.published_at DESC NULLS LAST, fi.fetched_at DESC"
    // Phase 1: skip filter is still GLOBAL. Phase 2 scopes to the current user.
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

// ===== Interest profile handling =====

func composeBlurb(categories: [String], freeform: String) -> String {
    let categoryNames: [String: String] = [
        "tech": "Tech, AI, and computer science",
        "politics": "Politics and current events (help me catch up on context I'm missing)",
        "world": "World news",
        "culture": "Culture, human drama, and what people are talking about",
        "business": "Business and finance",
        "science": "Science and health",
        "sports": "Sports (only when it crosses into cultural-event territory)"
    ]
    let selected = categories.compactMap { categoryNames[$0] }
    var parts: [String] = []
    if !selected.isEmpty {
        parts.append("Interested in: " + selected.joined(separator: "; ") + ".")
    }
    let trimmed = freeform.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { parts.append(trimmed) }
    return parts.joined(separator: "\n\n")
}

private func upsertUserProfile(userID: UUID, blurb: String, on req: Request) async throws {
    let ollama = OllamaClient(client: req.client)
    let embedding = try await ollama.embed(text: blurb)
    guard let sql = req.db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "expected SQLDatabase")
    }
    let existing = try await UserProfile.query(on: req.db)
        .filter(\.$user.$id == userID).first()
    if let existing = existing, let existingID = existing.id {
        try await sql.raw("""
            UPDATE user_profiles
            SET blurb = \(bind: blurb),
                embedding = \(unsafeRaw: "'\(pgvectorLiteral(embedding))'::vector"),
                updated_at = NOW()
            WHERE id = \(bind: existingID)
            """).run()
    } else {
        try await sql.raw("""
            INSERT INTO user_profiles (id, user_id, blurb, embedding, updated_at)
            VALUES (\(bind: UUID()),
                    \(bind: userID),
                    \(bind: blurb),
                    \(unsafeRaw: "'\(pgvectorLiteral(embedding))'::vector"),
                    NOW())
            """).run()
    }
}

// ===== View helpers =====

private func htmlResponse(_ html: String) -> Response {
    let response = Response(status: .ok, body: .init(string: html))
    response.headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
    return response
}

private struct CaptureJSON: Content {
    let id: UUID
    let status: String
}

// ===== Feed view =====

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

    private static func renderArticle(_ r: RankedRow) -> String {
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

enum CaptureView {
    static func renderForm(userEmail: String?, message: String?) -> String {
        let flash: String = {
            switch message {
            case "saved": return "<div class=\"flash ok\">Saved. We'll catch you up on this tomorrow.</div>"
            case "empty": return "<div class=\"flash err\">Can't save empty text.</div>"
            default: return ""
            }
        }()
        let emailTail = userEmail.map { " · <a href=\"/account\">\(htmlEscape($0))</a>" } ?? ""
        let body = """
        <main class="layout">
          <div class="list">
            <header>
              <h1>capture</h1>
              <div class="subtitle">Heard something? Drop it here — tomorrow's brief will surface what's relevant.</div>
              <nav><a href="/">← feed</a>\(emailTail)</nav>
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

enum CatchupView {
    static func renderPage(item: FeedItem, score: ItemScore?, explainerHTML: String) -> String {
        let body = """
        <main class="layout single">
          <div class="list">
            <header><nav><a href="/">← feed</a></nav></header>
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
            <header><nav><a href="/">← feed</a></nav></header>
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

// ===== Auth views =====

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
            <button type="submit">Log in</button>
          </form>
          <p class="auth-footer">Have an invite? <a href="/signup">Sign up</a></p>
        </div>
        """
        return page(title: "pulse / login", body: body)
    }
}

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

enum OnboardingView {
    static func render(email: String, currentBlurb: String?, message: String?, error: String?) -> String {
        let flash: String = {
            if error == "empty" { return "<div class=\"flash err\">Add at least one category or a sentence of interests.</div>" }
            return ""
        }()
        let blurbText = currentBlurb ?? ""
        func checked(_ key: String) -> String { blurbText.lowercased().contains(key) ? " checked" : "" }
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
                <label><input type="checkbox" name="categories" value="tech"\(checked("tech"))> Tech, AI, CS</label>
                <label><input type="checkbox" name="categories" value="politics"\(checked("politics"))> Politics &amp; current events</label>
                <label><input type="checkbox" name="categories" value="world"\(checked("world news"))> World news</label>
                <label><input type="checkbox" name="categories" value="culture"\(checked("culture"))> Culture, drama, what people are talking about</label>
                <label><input type="checkbox" name="categories" value="business"\(checked("business"))> Business &amp; finance</label>
                <label><input type="checkbox" name="categories" value="science"\(checked("science"))> Science &amp; health</label>
                <label><input type="checkbox" name="categories" value="sports"\(checked("sports"))> Sports (cultural moments only)</label>
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
              <h1>Account</h1>
              <div class="subtitle">Signed in as <strong>\(htmlEscape(email))</strong></div>
              <nav><a href="/">← feed</a></nav>
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

// ===== HTML shell =====

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
document.body.addEventListener('htmx:beforeRequest', (e) => {
  const el = e.detail?.elt;
  if (!el || !el.classList.contains('card')) return;
  document.querySelectorAll('.card.selected').forEach(c => c.classList.remove('selected'));
  el.classList.add('selected');
  openDetail();
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
  if (el && el.classList?.contains('engage') && e.detail?.successful) {
    const itemId = el.dataset.itemId;
    const isKeep = el.classList.contains('keep');
    const event = isKeep ? 'keep' : 'skip';
    document.querySelectorAll('.card[data-item-id="' + itemId + '"]').forEach(c => {
      c.classList.remove('kept', 'skipped');
      c.classList.add(event === 'keep' ? 'kept' : 'skipped');
    });
    const row = el.closest('.engagement-row');
    if (row) row.classList.add('voted', 'voted-' + event);
    el.disabled = true;
    setTimeout(() => closeDetail(), 420);
  }
});
document.body.addEventListener('htmx:afterSwap', (e) => {
  if (e.target && e.target.id === 'detail') openDetail();
});
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

main.layout{display:block;max-width:720px;margin:0 auto;padding:24px 16px}
main.layout.single{max-width:720px}
.list{width:100%}
.detail{display:none}

@media(min-width:900px){
  body.has-detail main.layout{max-width:1440px;display:grid;grid-template-columns:minmax(360px,1fr) minmax(480px,1.4fr);gap:40px;align-items:start}
  body.has-detail .list{max-width:none}
  body.has-detail .detail{display:block;position:sticky;top:24px;max-height:calc(100vh - 48px);overflow-y:auto;padding:8px 4px 24px 4px;animation:slideInRight 0.2s ease-out}
}
@keyframes slideInRight{from{opacity:0;transform:translateX(12px)}to{opacity:1;transform:translateX(0)}}
@media(max-width:899px){
  body.has-detail .detail{display:block;position:fixed;inset:0;background:var(--bg);overflow-y:auto;padding:24px 16px;z-index:10;animation:slideInUp 0.2s ease-out}
  body.has-detail .list{visibility:hidden}
}
@keyframes slideInUp{from{opacity:0;transform:translateY(16px)}to{opacity:1;transform:translateY(0)}}

header{margin-bottom:20px;padding-bottom:10px;border-bottom:1px solid var(--border)}
h1{font-size:28px;margin-bottom:4px;letter-spacing:-0.02em}
.subtitle{color:var(--muted);font-size:13px}
nav{margin-top:6px;font-size:13px;color:var(--muted)}
nav .user{float:right}

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

.card.kept{position:relative}
.card.kept::after{content:"✓ kept";position:absolute;top:14px;right:10px;font-size:10px;font-weight:700;color:#16a34a;letter-spacing:0.04em;text-transform:uppercase}
.card.skipped{opacity:0.5}
.card.skipped::after{content:"skipped";position:absolute;top:14px;right:10px;font-size:10px;font-weight:600;color:var(--muted);letter-spacing:0.04em;text-transform:uppercase}
@media(prefers-color-scheme:dark){.card.kept::after{color:#4ade80}}

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

.loading-state{min-height:240px;padding:8px 40px 24px 4px}
.loading-row{display:flex;gap:18px;align-items:center;padding:24px 0}
.spinner-lg{width:36px;height:36px;border:3px solid var(--border);border-top-color:var(--accent);border-radius:50%;animation:spin 0.7s linear infinite;flex-shrink:0}
.loading-meta{min-width:0}
.loading-label{font-size:11px;text-transform:uppercase;letter-spacing:0.08em;color:var(--muted);font-weight:700;margin-bottom:6px}
.loading-article{font-size:18px;font-weight:600;color:var(--text);line-height:1.35}

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

@keyframes spin{to{transform:rotate(360deg)}}

.capture-form,.auth-form,.onboard-form{display:flex;flex-direction:column;gap:12px;margin-top:16px;max-width:560px}
.capture-form label,.auth-form label,.onboard-form label{display:flex;flex-direction:column;gap:4px;font-size:13px;color:var(--muted)}
.capture-form textarea,.capture-form input,.auth-form input,.onboard-form textarea,.onboard-form input{font:inherit;padding:10px;border:1px solid var(--border);border-radius:6px;background:var(--card);color:var(--text);resize:vertical}
.capture-form button,.auth-form button,.onboard-form button{padding:10px 16px;font:inherit;font-weight:600;background:var(--accent);color:#fff;border:none;border-radius:6px;cursor:pointer;max-width:260px}
button.danger{background:#dc2626}
.flash{padding:10px 12px;border-radius:6px;margin:12px 0;font-size:14px;max-width:560px}
.flash.ok{background:#e8f5e9;color:var(--ok);border:1px solid var(--ok)}
.flash.err{background:#fef2f2;color:var(--err);border:1px solid var(--err)}

.auth-wrap{max-width:400px;margin:80px auto;padding:24px 16px}
.auth-footer{margin-top:16px;font-size:14px;color:var(--muted);text-align:center}

.onboard-form fieldset{border:1px solid var(--border);border-radius:6px;padding:12px 16px;margin-bottom:8px}
.onboard-form fieldset legend{padding:0 8px;font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:0.04em}
.onboard-form fieldset label{flex-direction:row;align-items:center;gap:8px;margin:6px 0;color:var(--text);font-size:14px;font-weight:normal}
.onboard-form fieldset label input{padding:0}

.account-section{padding:16px 0;border-bottom:1px solid var(--border);max-width:560px}
.account-section h2{font-size:16px;font-weight:600;margin-bottom:6px}
.account-section.danger-zone{border-top:1px solid #dc2626;margin-top:24px;padding-top:20px}
.account-section.danger-zone h2{color:#dc2626}
.btn-link{display:inline-block;padding:6px 12px;border:1px solid var(--border);border-radius:6px;font-size:13px}
.btn-link:hover{text-decoration:none;border-color:var(--accent)}
"""

// ===== File-private helpers =====

private func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&#39;")
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
