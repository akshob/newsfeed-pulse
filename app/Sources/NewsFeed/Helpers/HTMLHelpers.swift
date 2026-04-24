import Foundation

/// Escape a string for safe inclusion in HTML content.
func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&#39;")
}

/// Strip HTML tags and decode common entities from RSS/HTML content.
func stripTags(_ s: String) -> String {
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

/// Format a date as a compact relative-time string ("5m ago", "3d ago").
/// Returns empty string for nil.
func relativeTime(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let elapsed = Date().timeIntervalSince(date)
    if elapsed < 60 { return "just now" }
    if elapsed < 3600 { return "\(Int(elapsed/60))m ago" }
    if elapsed < 86400 { return "\(Int(elapsed/3600))h ago" }
    if elapsed < 86400*30 { return "\(Int(elapsed/86400))d ago" }
    return "\(Int(elapsed/(86400*30)))mo ago"
}
