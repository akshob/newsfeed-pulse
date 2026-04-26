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

    /// Polling target for the corner case: user submitted onboarding with
    /// NO categories ticked, only freeform — the LLM is parsing in the
    /// background. We meta-refresh this page every 2s; once
    /// user_profiles.categories is non-empty (parse done), redirect to /.
    func onboardingLoading(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let profile = try await UserProfile.query(on: req.db)
            .filter(\.$user.$id == user.requireID()).first()
        let cats = profile?.categories ?? []
        if !cats.isEmpty {
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
        let freeform = profile.map { freeformPart(of: $0.blurb) } ?? ""
        return htmlResponse(OnboardingView.render(
            email: user.email,
            currentCategories: cats,
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

        // Branch: corner case (no checkboxes, freeform only) → save with
        // empty categories, redirect to /onboarding/loading. The LLM parse
        // runs in the Task and populates categories + excluded_categories.
        // Once categories non-empty, the loading page redirects to /.
        //
        // Common case (≥1 checkbox) → save categories synchronously, redirect
        // to / immediately. LLM parse + rescore + catchup run in the Task.
        let isCornerCase = categories.isEmpty && !trimmedFreeform.isEmpty

        let initialCategories = categories  // empty for corner case, picks for common
        let initialBlurb = composeBlurb(categories: categories, freeform: freeform)

        do {
            try await upsertUserProfile(
                userID: userID,
                newBlurb: initialBlurb,
                newCategories: initialCategories,
                newExcludedCategories: [],
                on: req
            )
        } catch {
            onboardingLog(req, "onboarding/submit: upsertUserProfile failed for \(user.email): \(String(reflecting: error))", level: .error)
            throw error
        }
        onboardingLog(req, "onboarding/submit: success for \(user.email) cornerCase=\(isCornerCase)")

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
            await tlog("post-onboard pipeline: starting for \(email) cornerCase=\(isCornerCase)")

            // Phase 0 (corner case only): LLM-parse the freeform body to
            // extract include/exclude category lists. Update user_profiles
            // with the parsed lists. After this completes, the loading
            // page's poll will see non-empty categories and redirect.
            if isCornerCase {
                let chatModel = Environment.get("OLLAMA_CHAT_MODEL") ?? "qwen2.5:7b"
                let ollama = OllamaClient(client: app.client)
                let parsed = await parseFreeformInterests(
                    text: trimmedFreeform,
                    ollama: ollama,
                    model: chatModel
                )
                let resolvedInclude = parsed.include.isEmpty
                    ? Array(["tech", "politics", "world", "culture", "business", "science", "sports"])  // fallback
                    : parsed.include
                await tlog("post-onboard parse: \(email) include=\(resolvedInclude) exclude=\(parsed.exclude) (fallback=\(parsed.include.isEmpty))")

                // Re-compose blurb against the parsed categories so the
                // structured prefix is correct. Use the application-scoped
                // request-less path: open a one-shot client + db, write
                // directly via raw SQL.
                guard let sql = app.db as? any SQLDatabase else {
                    await OnboardingFileLogger.shared.append(
                        "post-onboard parse: \(email) failed — no SQL database", level: "error"
                    )
                    return
                }
                let newBlurb = composeBlurb(categories: resolvedInclude, freeform: trimmedFreeform)
                let escapeArr: ([String]) -> String = { values in
                    let escaped = values.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
                        .joined(separator: ",")
                    return "ARRAY[\(escaped)]::TEXT[]"
                }
                do {
                    try await sql.raw("""
                        UPDATE user_profiles
                        SET blurb = \(bind: newBlurb),
                            categories          = \(unsafeRaw: escapeArr(resolvedInclude)),
                            excluded_categories = \(unsafeRaw: escapeArr(parsed.exclude)),
                            updated_at = NOW()
                        WHERE user_id = \(bind: userID)
                        """).run()
                    await tlog("post-onboard parse: \(email) saved new categories")
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

        // Corner case → loading page (Task above will populate categories,
        // poller redirects once that's done). Common case → straight to feed.
        return isCornerCase
            ? req.redirect(to: "/onboarding/loading")
            : req.redirect(to: "/?msg=interests_saved")
    }
}
