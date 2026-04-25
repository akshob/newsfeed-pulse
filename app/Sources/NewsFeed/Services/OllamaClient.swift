import Foundation
import Vapor

// Thin HTTP wrapper around Ollama's embed and chat endpoints.
//
// We route embeddings and chat to (potentially) different hosts so user-facing
// paths (onboarding, capture) don't depend on the heavy chat box. Typical prod:
//   OLLAMA_EMBED_BASE_URL = http://localhost:11434   (small embedder on hydrogen)
//   OLLAMA_BASE_URL       = http://oxygen.local:11434 (chat models on M1 Max)
// Either var alone falls through to the other, then to localhost — so dev with
// a single Ollama keeps working unchanged.
struct OllamaClient {
    let client: any Client
    let embedBaseURL: String
    let chatBaseURL: String

    init(client: any Client, embedBaseURL: String? = nil, chatBaseURL: String? = nil) {
        self.client = client
        let fallback = Environment.get("OLLAMA_BASE_URL") ?? "http://localhost:11434"
        self.embedBaseURL = embedBaseURL ?? Environment.get("OLLAMA_EMBED_BASE_URL") ?? fallback
        self.chatBaseURL = chatBaseURL ?? Environment.get("OLLAMA_CHAT_BASE_URL") ?? fallback
    }

    // MARK: - Embeddings

    struct EmbedRequest: Content {
        let model: String
        let input: String
    }
    struct EmbedResponse: Content {
        let embeddings: [[Double]]
    }

    func embed(model: String = "nomic-embed-text", text: String) async throws -> [Double] {
        let resp = try await client.post(URI(string: "\(embedBaseURL)/api/embed")) { req in
            try req.content.encode(EmbedRequest(model: model, input: text))
        }
        guard resp.status == .ok else {
            throw Abort(.internalServerError, reason: "ollama embed failed: HTTP \(resp.status.code)")
        }
        let body = try resp.content.decode(EmbedResponse.self)
        guard let first = body.embeddings.first else {
            throw Abort(.internalServerError, reason: "ollama returned no embedding")
        }
        return first
    }

    // MARK: - Chat

    struct ChatMessage: Content {
        let role: String
        let content: String
    }
    struct ChatRequest: Content {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let format: String?
        let options: ChatOptions?
    }
    struct ChatOptions: Content {
        let temperature: Double?
        let num_ctx: Int?
    }
    struct ChatResponse: Content {
        let message: ChatMessage
    }

    func chat(
        model: String,
        system: String? = nil,
        user: String,
        jsonMode: Bool = false,
        temperature: Double? = 0.2,
        numCtx: Int? = 4096
    ) async throws -> String {
        var messages: [ChatMessage] = []
        if let system = system {
            messages.append(ChatMessage(role: "system", content: system))
        }
        messages.append(ChatMessage(role: "user", content: user))

        let resp = try await client.post(URI(string: "\(chatBaseURL)/api/chat")) { req in
            try req.content.encode(ChatRequest(
                model: model,
                messages: messages,
                stream: false,
                format: jsonMode ? "json" : nil,
                options: ChatOptions(temperature: temperature, num_ctx: numCtx)
            ))
        }
        guard resp.status == .ok else {
            throw Abort(.internalServerError, reason: "ollama chat failed: HTTP \(resp.status.code)")
        }
        let body = try resp.content.decode(ChatResponse.self)
        return body.message.content
    }
}

// NOTE: cosineSimilarity, pgvectorLiteral, parsePGVector moved to Helpers/VectorMath.swift.
