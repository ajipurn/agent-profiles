import SwiftUI

/// How a provider is labeled and tinted across the menu and Settings.
public struct ProviderStyle: Equatable, Sendable {
    public let name: String
    public let symbol: String
    public let accent: Color

    public static let claude = ProviderStyle(
        name: "Claude", symbol: "asterisk",
        accent: Color(red: 0.85, green: 0.47, blue: 0.34))
    public static let codex = ProviderStyle(
        name: "Codex", symbol: "chevron.left.forwardslash.chevron.right",
        accent: Color(red: 0.13, green: 0.66, blue: 0.56))

    /// Remaining-limit bars use one tint for every provider so they read the
    /// same at a glance; `accent` stays for provider identity.
    public static let usageTint = Color.accentColor
}
