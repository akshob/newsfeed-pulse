import Foundation
import Logging
import Vapor

/// Writes onboarding-related log lines to a daily-rotated file under
/// `logs/onboarding/`, mirroring the pattern used by the cron pipeline
/// (`logs/ingest/ingest-*.log`, `logs/catchup/...`).
///
/// Lines are also written to the regular req.logger (so journald keeps
/// receiving them) — the file is an additional sink for triage, not a
/// replacement.
actor OnboardingFileLogger {
    static let shared = OnboardingFileLogger()

    private var handle: FileHandle?
    private var dayStamp: String = ""
    private let dir: URL

    init(dir: URL? = nil) {
        if let dir = dir {
            self.dir = dir
        } else {
            // Vapor's WorkingDirectory in prod is the app/ folder; logs live
            // alongside the package at <repo>/logs/onboarding.
            let cwd = FileManager.default.currentDirectoryPath
            self.dir = URL(fileURLWithPath: cwd)
                .appendingPathComponent("../logs/onboarding")
                .standardizedFileURL
        }
        try? FileManager.default.createDirectory(
            at: self.dir, withIntermediateDirectories: true
        )
    }

    func append(_ message: String, level: String) {
        let now = Date()
        let day = OnboardingFileLogger.dayString(from: now)
        let stamp = OnboardingFileLogger.stampString(from: now)

        if day != dayStamp {
            try? handle?.close()
            let path = dir.appendingPathComponent("onboarding-\(day).log")
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

    /// `2026-04-25` (UTC) — used for the daily filename.
    static func dayString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// `2026-04-25T11:32:14.123Z` — used as the line prefix.
    static func stampString(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

/// Marks a request as part of an onboarding flow so downstream code (e.g.
/// upsertUserProfile, which is also called from capture) can decide whether
/// to mirror its log lines to the onboarding file.
struct OnboardingContextKey: StorageKey {
    typealias Value = Bool
}

extension Request {
    var isOnboardingContext: Bool {
        get { storage[OnboardingContextKey.self] ?? false }
        set { storage[OnboardingContextKey.self] = newValue }
    }
}

/// Log to req.logger AND to the onboarding file. Use from the onboarding
/// controller for lines that are unconditionally onboarding-relevant.
func onboardingLog(
    _ req: Request,
    _ message: String,
    level: Logger.Level = .info
) {
    req.logger.log(level: level, "\(message)")
    let levelText = "\(level)"
    Task {
        await OnboardingFileLogger.shared.append(message, level: levelText)
    }
}

/// Log to req.logger always; mirror to the onboarding file only when the
/// request is in onboarding context. Use this from shared helpers that may
/// be called from multiple flows (e.g. upsertUserProfile is hit by both
/// onboarding and capture).
func contextualLog(
    _ req: Request,
    _ message: String,
    level: Logger.Level = .info
) {
    req.logger.log(level: level, "\(message)")
    guard req.isOnboardingContext else { return }
    let levelText = "\(level)"
    Task {
        await OnboardingFileLogger.shared.append(message, level: levelText)
    }
}
