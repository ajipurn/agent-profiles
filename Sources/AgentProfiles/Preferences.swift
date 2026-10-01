import Foundation
import AgentUI

/// Which provider the menu bar icon follows.
enum MenuBarProvider: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }
    var style: ProviderStyle { self == .claude ? .claude : .codex }

    /// The provider whose desktop app has this bundle ID. Terminals are left
    /// out: they could be running either CLI.
    init?(frontmostBundleID: String?) {
        switch frontmostBundleID {
        case "com.anthropic.claudefordesktop": self = .claude
        case "com.openai.codex": self = .codex
        default: return nil
        }
    }
}

/// App-level settings kept in UserDefaults (each provider keeps its own).
enum Preferences {
    static let menuBarProviderKey = "menuBarProvider"
    static let showPercentKey = "showMenuBarPercent"
    static let followActiveAppKey = "menuBarFollowsActiveApp"

    static var menuBarProvider: MenuBarProvider? {
        get { UserDefaults.standard.string(forKey: menuBarProviderKey).flatMap(MenuBarProvider.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: menuBarProviderKey) }
    }

    /// Show the provider of the frontmost Claude or Codex app; on unless
    /// turned off.
    static var followActiveApp: Bool {
        UserDefaults.standard.object(forKey: followActiveAppKey) as? Bool ?? true
    }

    /// Percentage text next to the icon; on unless turned off.
    static var showPercent: Bool {
        UserDefaults.standard.object(forKey: showPercentKey) as? Bool ?? true
    }
}
