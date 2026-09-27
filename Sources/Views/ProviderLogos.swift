import AppKit

/// Bundle-shipped provider marks (template PDFs), shared by any view that
/// prints a Claude/OpenAI logo outside the island itself (turn alarm, the
/// reset-card chip, the weekly report card).
enum ProviderLogos {
    static let claude = load("claude_logo")
    static let openAI = load("openai_logo")
    static let cursor = load("cursor_logo")
    static let grok = load("grok_logo")
    static let gemini = load("gemini_logo")

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }
}
