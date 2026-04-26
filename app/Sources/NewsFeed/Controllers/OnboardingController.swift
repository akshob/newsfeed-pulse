import Fluent
import Foundation
import SQLKit
import Vapor

struct OnboardingController {
    func boot(routes: any RoutesBuilder) {
        routes.get("onboarding", use: self.onboardingForm)
        routes.post("onboarding", use: self.onboardingSubmit)
        routes.get("onboarding", "loading", use: self.onboardingLoading)
    }

    /// Polling target shown after every onboarding submit. Meta-refreshes
    /// every 2s; redirects to / once either:
    ///   - the user has at least 1 user_item_scores row freshly written
    ///     against their current profile (rescoreUser progress threshold —
    ///     guarantees the top of the feed has personalized card text), OR
    ///   - more than 30s have passed since the profile update (safety
    ///     timeout so a slow / failing background pipeline never traps
    ///     the user).
    ///
    /// Freshness via `scored_at >= profile.updated_at` — also covers the
    /// re-onboard case where stale rows exist from a previous blurb.
    func onboardingLoading(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        guard let sql = req.db as? any SQLDatabase else {
            return req.redirect(to: "/?msg=interests_saved")
        }
        struct StatusRow: Decodable {
            let fresh_scores: Int
            let seconds_since_update: Double?
        }
        let row = try await sql.raw("""
            WITH p AS (
              SELECT updated_at FROM user_profiles
              WHERE user_id = \(bind: userID) LIMIT 1
            )
            SELECT
              COALESCE((
                SELECT COUNT(*)::int FROM user_item_scores uis
                WHERE uis.user_id = \(bind: userID)
                  AND uis.scored_at >= (SELECT updated_at FROM p)
              ), 0) AS fresh_scores,
              EXTRACT(EPOCH FROM (NOW() - (SELECT updated_at FROM p)))::float AS seconds_since_update
            """).first(decoding: StatusRow.self)
        let freshScores = row?.fresh_scores ?? 0
        let elapsed = row?.seconds_since_update ?? 999
        if freshScores >= 1 || elapsed > 30 {
            return req.redirect(to: "/?msg=interests_saved")
        }
        return htmlResponse(OnboardingLoadingView.render(email: user.email))
    }

    // GET /onboarding
    func onboardingForm(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == user.requireID()).first()
        let cats = profile?.categories ?? []
        let inferred = profile?.inferredCategories ?? []
        let freeform = profile.map { freeformPart(of: $0.blurb) } ?? ""
        return htmlResponse(OnboardingView.render(
            email: user.email,
            currentCategories: cats,
            currentInferredCategories: inferred,
            currentFreeform: freeform,
            message: try? req.query.get(String.self, at: "msg"),
            error: try? req.query.get(String.self, at: "err")
        ))
    }

    // POST /onboarding — persist categories + freeform as an embedded user_profile.
    // Phase 1 of the redesign: store `categories` explicitly (no more
    // substring-matching the blurb to derive checkbox state). The blurb
    // column still holds composed text for the embedder. LLM-parse of the
    // freeform body for excluded_categories ships in Phase 2.
    func onboardingSubmit(req: Request) async throws -> Response {
        struct Form: Content {
            var categories: [String]?
            var freeform: String?
        }
        req.isOnboardingContext = true
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        onboardingLog(req, "onboarding/submit: user=\(user.email)")

        let form: Form
        do {
            form = try req.content.decode(Form.self)
        } catch {
            onboardingLog(req, "onboarding/submit: form decode failed: \(String(reflecting: error))", level: .error)
            throw error
        }
        let categories = form.categories ?? []
        let freeform = form.freeform ?? ""
        onboardingLog(req, "onboarding/submit: categories=\(categories) freeformLen=\(freeform.count)")

        let trimmedFreeform = freeform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !categories.isEmpty || !trimmedFreeform.isEmpty else {
            return req.redirect(to: "/onboarding?err=empty")
        }

        // Save the user's explicit categories + the composed blurb
        // synchronously. Reset inferred + excluded to empty pending the
        // LLM parse below. Whether or not freeform is present, this is
        // the source-of-truth state at submit time.
        let initialBlurb = composeBlurb(categories: categories, freeform: freeform)
        do {
            try await upsertUserProfile(
                userID: userID,
                newBlurb: initialBlurb,
                newCategories: categories,
                newInferredCategories: [],
                newExcludedCategories: [],
                on: req
            )
        } catch {
            onboardingLog(req, "onboarding/submit: upsertUserProfile failed for \(user.email): \(String(reflecting: error))", level: .error)
            throw error
        }
        let willRunLLMParse = !trimmedFreeform.isEmpty
        onboardingLog(req, "onboarding/submit: success for \(user.email) llmParse=\(willRunLLMParse)")

        // Fire-and-forget per-user LLM rerank so the user starts seeing
        // personalized cards within a few minutes instead of waiting for the
        // top-of-hour cron tick. The Task captures `application` and `logger`
        // (long-lived / value-typed); req itself is gone by the time it runs.
        let app = req.application
        let logger = req.logger
        let email = user.email
        @Sendable func tlog(_ msg: String) async {
            await OnboardingFileLogger.shared.append(msg, level: "info")
        }
        Task.detached {
            await tlog("post-onboard pipeline: starting for \(email) llmParse=\(willRunLLMParse)")

            // Phase 0: LLM-parse the freeform body whenever it's non-empty,
            // regardless of whether the user also picked checkboxes. The
            // result lands in `inferred_categories` (separate from `categories`)
            // so the form's checkbox state continues to reflect ONLY the
            // user's explicit selection — no false-positive ticks. Excluded
            // categories from negative phrases ("no politics") still go in
            // excluded_categories.
            if willRunLLMParse {
                let chatModel = Environment.get("OLLAMA_CHAT_MODEL") ?? "qwen2.5:7b"
                let ollama = OllamaClient(client: app.client)
                let parsed = await parseFreeformInterests(
                    text: trimmedFreeform,
                    ollama: ollama,
                    model: chatModel
                )
                await tlog("post-onboard parse: \(email) inferred=\(parsed.include) exclude=\(parsed.exclude)")

                guard let sql = app.db as? any SQLDatabase else {
                    await OnboardingFileLogger.shared.append(
                        "post-onboard parse: \(email) failed — no SQL database", level: "error"
                    )
                    return
                }
                let escapeArr: ([String]) -> String = { values in
                    let escaped = values.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
                        .joined(separator: ",")
                    return "ARRAY[\(escaped)]::TEXT[]"
                }
                do {
                    try await sql.raw("""
                        UPDATE user_profiles
                        SET inferred_categories = \(unsafeRaw: escapeArr(parsed.include)),
                            excluded_categories = \(unsafeRaw: escapeArr(parsed.exclude))
                        WHERE user_id = \(bind: userID)
                        """).run()
                    await tlog("post-onboard parse: \(email) saved inferred + excluded")
                } catch {
                    await OnboardingFileLogger.shared.append(
                        "post-onboard parse: \(email) DB update failed: \(String(reflecting: error))", level: "error"
                    )
                    return
                }
            }

            // Phase A: per-user LLM rerank — gets card text personalized.
            do {
                let count = try await rescoreUser(
                    userID: userID,
                    application: app,
                    logger: logger,
                    fileLog: tlog
                )
                let msg = "post-onboard rescore: \(email) scored \(count) items"
                logger.info("\(msg)")
                await tlog(msg)
            } catch {
                let msg = "post-onboard rescore: \(email) failed: \(String(reflecting: error))"
                logger.error("\(msg)")
                await OnboardingFileLogger.shared.append(msg, level: "error")
                return
            }

            // Phase B: pre-generate catchup HTML for the top items this user
            // is about to see. Runs sequentially after rescore so the "top"
            // query uses fresh per-user scores.
            do {
                let count = try await catchupTopItemsForUser(
                    userID: userID,
                    application: app,
                    logger: logger,
                    fileLog: tlog
                )
                let msg = count > 0
                    ? "post-onboard catchup: \(email) generated \(count) explainers"
                    : "post-onboard catchup: \(email) — nothing pending"
                logger.info("\(msg)")
                await tlog(msg)
            } catch {
                let msg = "post-onboard catchup: \(email) failed: \(String(reflecting: error))"
                logger.error("\(msg)")
                await OnboardingFileLogger.shared.append(msg, level: "error")
            }
        }

        // Always route through the loading page so the user lands on a
        // ranked feed (≥1 fresh user_item_scores row) instead of one
        // showing global fallback text on top items. Loading page redirects
        // to / as soon as rescoreUser writes the first per-user row, or
        // after a 30s safety timeout.
        return req.redirect(to: "/onboarding/loading")
    }
}
