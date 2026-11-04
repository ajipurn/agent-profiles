import SwiftUI

/// How a provider is labeled and tinted across the menu and Settings.
public struct ProviderStyle: Equatable, Sendable, Identifiable {
    /// Stable key ("claude", "gemini"); picks the vendored logo.
    public let id: String
    public let name: String
    /// SF Symbol for providers without a vendored logo.
    public let symbol: String
    public let accent: Color

    public init(id: String, name: String, symbol: String, accent: Color) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.accent = accent
    }

    /// From a "#RRGGBB" brand color.
    public init(id: String, name: String, symbol: String, hex: String) {
        self.init(id: id, name: name, symbol: symbol, accent: Color(hex: hex) ?? .gray)
    }

    public static let claude = ProviderStyle(
        id: "claude", name: "Claude", symbol: "asterisk",
        accent: Color(red: 0.85, green: 0.47, blue: 0.34))
    public static let codex = ProviderStyle(
        id: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right",
        accent: Color(red: 0.31, green: 0.42, blue: 0.97))

    /// Remaining-limit bars use one tint for every provider so they read the
    /// same at a glance; `accent` stays for provider identity.
    public static let usageTint = Color.accentColor
}

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
