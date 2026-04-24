import Crypto
import Foundation

/// Deterministic identicon: 5×5 horizontally-symmetric grid, hue derived from
/// a SHA-256 hash of the seed (usually the user's email). Returns inline SVG.
func identiconSVG(for seed: String, size: Int = 32) -> String {
    let digest = SHA256.hash(data: Data(seed.lowercased().utf8))
    let bytes = Array(digest)
    let cols = 5, rows = 5
    let cell = size / cols
    let padded = size - cell * cols  // rounding remainder

    let hue = Int(bytes[bytes.count - 1]) * 360 / 256
    let fill = "hsl(\(hue), 55%, 48%)"

    var rects = ""
    // Fill cells based on bit 0 of each byte; mirror the left 2 cols to the right
    for row in 0..<rows {
        for col in 0..<3 {
            let byte = bytes[row * 3 + col]
            if byte & 1 == 0 {
                let x = col * cell
                let y = row * cell
                rects += "<rect x='\(x)' y='\(y)' width='\(cell)' height='\(cell)'/>"
                if col < 2 {
                    let mirrorX = (cols - 1 - col) * cell
                    rects += "<rect x='\(mirrorX)' y='\(y)' width='\(cell)' height='\(cell)'/>"
                }
            }
        }
    }

    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(size)" height="\(size)" viewBox="0 0 \(size - padded) \(size - padded)" aria-hidden="true" focusable="false" shape-rendering="crispEdges">
      <rect width="100%" height="100%" fill="#f3f4f6"/>
      <g fill="\(fill)">\(rects)</g>
    </svg>
    """
}

/// Little `<a>` wrapper linking to /account with the identicon inside.
/// Returns empty string for nil/empty email.
func avatarHTML(for email: String?, size: Int = 32) -> String {
    guard let email = email, !email.isEmpty else { return "" }
    return """
    <a class="avatar-link" href="/account" title="\(email)" aria-label="your account">
      <span class="avatar">\(identiconSVG(for: email, size: size))</span>
    </a>
    """
}
