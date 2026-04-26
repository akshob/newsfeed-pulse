import Foundation

/// Brief "we're personalizing your feed" interstitial shown only when the
/// user submitted onboarding with NO checkboxes ticked, leaving the
/// freeform body as the only signal. The LLM parses that text in the
/// background; this page meta-refreshes every 2s and the GET handler
/// redirects to / as soon as user_profiles.categories is non-empty.
enum OnboardingLoadingView {
    static func render(email: String) -> String {
        let body = """
        <main class="layout">
          <div class="list" style="text-align:center; padding-top:4rem;">
            <h1>Building your feed…</h1>
            <p class="subtitle" style="margin-top:1rem;">
              Reading what you wrote and matching it against the news categories.
              This page will refresh automatically when your feed is ready (usually 5–15 seconds).
            </p>
            <div style="margin: 2.5rem auto; width: 48px; height: 48px; border: 4px solid #e2e2e2; border-top-color: #2a7ad9; border-radius: 50%; animation: spin 0.9s linear infinite;"></div>
            <p style="opacity:0.6; font-size:0.9rem;">If this takes more than 30 seconds, <a href="/onboarding">go back and tick a category</a> instead.</p>
          </div>
        </main>
        <style>
          @keyframes spin { to { transform: rotate(360deg); } }
        </style>
        """
        return page(
            title: "pulse / building your feed",
            body: body,
            extraHead: "<meta http-equiv=\"refresh\" content=\"2\">"
        )
    }
}
