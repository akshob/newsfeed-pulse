import Fluent
import Foundation
import Vapor

final class Capture: Model, @unchecked Sendable {
    static let schema = "captures"

    @ID(key: .id) var id: UUID?
    @Field(key: "content") var content: String
    @OptionalField(key: "source_hint") var sourceHint: String?
    @Timestamp(key: "captured_at", on: .create) var capturedAt: Date?
    @OptionalField(key: "processed_at") var processedAt: Date?
    @OptionalField(key: "extracted_topics") var extractedTopics: String?  // JSON as text for now

    init() {}

    init(content: String, sourceHint: String? = nil) {
        self.content = content
        self.sourceHint = sourceHint
    }
}
