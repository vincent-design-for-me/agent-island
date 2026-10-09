import Foundation

/// A single billable unit of token consumption parsed from a local session log.
/// Both `ClaudeLogReader` and `CodexLogReader` emit these so the cost pipeline
/// downstream is provider-agnostic.
struct TokenEvent {
    enum Provider {
        case claude
        case codex
    }

    let provider: Provider
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    /// Tokens written to the prompt cache during this turn. Anthropic-only.
    let cacheCreationTokens: Int
    /// Tokens served from the prompt cache during this turn. Both providers
    /// (Codex calls these "cached_input_tokens" — they are billed at a
    /// discount but still draw from the input bucket).
    let cacheReadTokens: Int
    /// The part of `cacheCreationTokens` written to the 1-hour cache, billed
    /// at 2x input instead of the 5-minute cache's 1.25x. Anthropic-only.
    var cacheCreation1hTokens: Int = 0
    /// Claude Code fast mode (`/fast`), billed at a premium on supported Opus models.
    var fast: Bool = false
    /// Pins the long-prompt pricing tier for archive-replayed events, whose
    /// summed tokens no longer reflect any single request's prompt length.
    var longPromptOverride: Bool? = nil

    /// Prompt length as Anthropic counts it for tiered pricing: every input
    /// token of the request, cache reads and writes included.
    var promptTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }
}
