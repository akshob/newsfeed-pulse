import Fluent
import Foundation
import Vapor

struct CaptureController {
    func boot(routes: any RoutesBuilder) {
        routes.get("capture", use: self.captureForm)
        routes.post("capture", use: self.captureSubmit)
    }

    // GET /capture
    func captureForm(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        return htmlResponse(CaptureView.renderForm(
            userEmail: user.email,
            message: try? req.query.get(String.self, at: "msg")
        ))
    }

    // POST /capture — accepts form-encoded or JSON
    func captureSubmit(req: Request) async throws -> Response {
        struct Form: Content {
            var content: String?
            var source_hint: String?
        }
        struct JSONResponse: Content { let id: UUID; let status: String }
        let user = try req.auth.require(User.self)
        let form = try req.content.decode(Form.self)
        guard let content = form.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return req.redirect(to: "/capture?msg=empty")
        }
        let hint = form.source_hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userID = try user.requireID()
        let capture = Capture(
            userID: userID,
            content: content,
            sourceHint: hint?.isEmpty == true ? nil : hint
        )
        try await capture.save(on: req.db)

        // Recompute the user's profile embedding so this capture starts
        // influencing ranking on the next page load. The blurb stays as-is;
        // captures bias the embedding toward whatever they just heard.
        // Errors here don't block the save — capture is the user-visible win.
        do {
            try await upsertUserProfile(userID: userID, on: req)
        } catch {
            req.logger.error("capture: profile re-embed failed: \(error)")
        }

        if req.headers.contentType == .json ||
           req.headers.first(name: .accept)?.contains("application/json") == true {
            return try await JSONResponse(id: capture.id!, status: "saved").encodeResponse(for: req)
        }
        return req.redirect(to: "/capture?msg=saved")
    }
}
