import Vapor

/// Wire route groups to controllers. Public routes (login, signup, health)
/// sit at the top level; everything else is behind `AuthRedirectMiddleware`
/// so unauthenticated visits redirect to /login (and HTMX requests receive
/// `HX-Redirect` so the login page doesn't get injected into a detail pane).
func routes(_ app: Application) throws {
    // Public
    AuthController().boot(routes: app)
    app.get("hello") { _ async in "Hello, world!" }
    app.get("healthz") { _ async in "ok" }
    app.get("favicon.svg") { _ async -> Response in
        let response = Response(status: .ok, body: .init(string: faviconSVG))
        response.headers.replaceOrAdd(name: .contentType, value: "image/svg+xml")
        response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=604800")
        return response
    }

    // Protected
    let protected = app.grouped(AuthRedirectMiddleware(loginPath: "/login"))
    FeedController().boot(routes: protected)
    CaptureController().boot(routes: protected)
    CatchupController().boot(routes: protected)
    EngageController().boot(routes: protected)
    OnboardingController().boot(routes: protected)
    AccountController().boot(routes: protected)
}
