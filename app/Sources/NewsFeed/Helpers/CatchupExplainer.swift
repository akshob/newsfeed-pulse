import Foundation
import Vapor

/// Generate a "catch me up" HTML explainer for a single news item via the
/// chat LLM. Used by:
/// - CatchupAllCommand (cron batch, processes everything missing an explainer)
/// - catchupTopItemsForUser (post-login / post-onboarding hot path, focused
///   on the few items this user is about to see)
///
/// Output is HTML using only h2/p/ul/li/strong tags — meant to render directly
/// inside a div on the right pane without further sanitization.
func buildExplainer(
    ollama: OllamaClient,
    model: String,
    title: String,
    source: String,
    body: String?
) async throws -> String {
    let cleanBody = (body.map(stripTags) ?? "").prefix(2000)

    let system = """
    You are a neutral news explainer for someone smart who hasn't been following the story. \
    Present both sides' strongest case fairly. Never opine. Output clean HTML only, no markdown.
    """

    let user = """
    Item title: \(title)
    Source: \(source)
    Body: \(cleanBody)

    Write a catch-me-up explainer using ONLY these HTML tags: <h2>, <p>, <ul>, <li>, <strong>.
    Do not wrap in <html>, <body>, or <article>.

    Structure:
    <h2>Background</h2>
    <p>2-3 sentences of historical context. Who/what are the key players? When did this start?</p>

    <h2>What's new</h2>
    <p>1-2 sentences on what just happened that made this newsworthy now.</p>

    <h2>The two strongest takes</h2>
    <ul>
      <li><strong>One side says:</strong> steelman their case in 1-2 sentences</li>
      <li><strong>The other side says:</strong> steelman their case in 1-2 sentences</li>
    </ul>

    <h2>Conversation starter</h2>
    <p>One specific angle or question you could raise.</p>

    Rules:
    - If this is clearly a factual item with no controversy (weather, obituary, tech release), skip the "two strongest takes" section entirely.
    - Do not add any commentary outside the structure.
    """

    return try await ollama.chat(
        model: model,
        system: system,
        user: user,
        jsonMode: false,
        temperature: 0.3,
        numCtx: 4096
    )
}
