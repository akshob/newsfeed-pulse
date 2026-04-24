import Foundation
import Vapor

/// In-memory sliding-window rate limiter keyed by client IP.
/// State is lost on server restart — acceptable given the use case (defense
/// against abusive bursts, not a compliance-grade audit log).
actor RateLimiter {
    private var events: [String: [Date]] = [:]
    let maxEvents: Int
    let window: TimeInterval

    init(maxEvents: Int, window: TimeInterval) {
        self.maxEvents = maxEvents
        self.window = window
    }

    /// Returns true and records an event if under the limit; returns false otherwise.
    func allow(key: String, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        var times = (events[key] ?? []).filter { $0 >= cutoff }
        if times.count >= maxEvents {
            events[key] = times
            return false
        }
        times.append(now)
        events[key] = times
        return true
    }

    /// For tests only — inject events at an arbitrary time.
    func record(key: String, at date: Date) {
        events[key, default: []].append(date)
    }
}

struct RateLimitMiddleware: AsyncMiddleware {
    let limiter: RateLimiter

    init(maxEvents: Int, window: TimeInterval) {
        self.limiter = RateLimiter(maxEvents: maxEvents, window: window)
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let key = Self.clientKey(from: request)
        let allowed = await limiter.allow(key: key)
        if !allowed {
            return Response(
                status: .tooManyRequests,
                body: .init(string: "Too many requests. Please wait a bit and try again.")
            )
        }
        return try await next.respond(to: request)
    }

    /// Prefer Cloudflare's `CF-Connecting-IP` since traffic transits through CF;
    /// fall back to the first `X-Forwarded-For` entry (set by Caddy);
    /// finally the direct remote address (probably 127.0.0.1 since Vapor binds
    /// localhost, but at least it won't crash).
    static func clientKey(from req: Request) -> String {
        if let cf = req.headers.first(name: "CF-Connecting-IP")?
            .trimmingCharacters(in: .whitespaces), !cf.isEmpty {
            return cf
        }
        if let xff = req.headers.first(name: "X-Forwarded-For")?
            .split(separator: ",").first
            .map({ String($0).trimmingCharacters(in: .whitespaces) }),
           !xff.isEmpty {
            return xff
        }
        return req.remoteAddress?.ipAddress ?? "unknown"
    }
}
