import Foundation
import Logging
import Vapor

/// Writes login/signup attempts to a daily-rotated file at
/// `logs/auth/auth-YYYY-MM-DD.log`. Same shape as OnboardingFileLogger.
///
/// Each line is also written to req.logger so journald keeps a copy; the
/// file is an additional sink for triage. Includes the entered email and
/// client IP — useful for spotting credential-stuffing or invite-grinding,
/// at the cost of putting emails on disk in plaintext (acceptable for a
/// single-tenant home server with a handful of invited users).
actor AuthFileLogger {
    static let shared = AuthFileLogger()

    private var handle: FileHandle?
    private var dayStamp: String = ""
    private let dir: URL

    init(dir: URL? = nil) {
        if let dir = dir {
            self.dir = dir
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            self.dir = URL(fileURLWithPath: cwd)
                .appendingPathComponent("../logs/auth")
                .standardizedFileURL
        }
        try? FileManager.default.createDirectory(
            at: self.dir, withIntermediateDirectories: true
        )
    }

    func append(_ message: String, level: String) {
        let now = Date()
        let day = AuthFileLogger.dayString(from: now)
        let stamp = AuthFileLogger.stampString(from: now)

        if day != dayStamp {
            try? handle?.close()
            let path = dir.appendingPathComponent("auth-\(day).log")
            if !FileManager.default.fileExists(atPath: path.path) {
                FileManager.default.createFile(atPath: path.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: path)
            try? handle?.seekToEnd()
            dayStamp = day
        }

        let line = "\(stamp) [\(level)] \(message)\n"
        if let data = line.data(using: .utf8), let h = handle {
            try? h.write(contentsOf: data)
        }
    }

    static func dayString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    static func stampString(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

/// Log to req.logger AND to the auth file. Use from AuthController so each
/// login/signup attempt leaves a breadcrumb regardless of outcome.
func authLog(
    _ req: Request,
    _ message: String,
    level: Logger.Level = .info
) {
    req.logger.log(level: level, "\(message)")
    let levelText = "\(level)"
    Task {
        await AuthFileLogger.shared.append(message, level: levelText)
    }
}
