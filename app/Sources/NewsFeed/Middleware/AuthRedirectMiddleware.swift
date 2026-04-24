import Vapor

/// Redirects unauthenticated web requests to `/login`. For HTMX (XHR) requests,
/// returns 401 + `HX-Redirect` header so HTMX does a clean full-page redirect
/// instead of injecting the login form into an in-page target.
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
