/// Every provider beyond Claude and Codex, in the order Settings lists them.
public enum ProviderRegistry {
    public static let all: [any UsageProvider] = [
        GeminiProvider(),
        AntigravityProvider(),
        CursorProvider(),
        CopilotProvider(),
        OpenCodeProvider(),
        KiroProvider(),
        GrokProvider(),
    ]
}
