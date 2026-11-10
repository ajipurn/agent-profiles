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

/// Which window the menu bar percentage shows.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case session, weekly, tighter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .tighter: "Whichever is lower"
        }
    }

    func value(session: Double?, weekly: Double?) -> Double? {
        switch self {
        case .session: session ?? weekly
        case .weekly: weekly ?? session
        case .tighter: [session, weekly].compactMap { $0 }.min()
        }
    }
}

/// App-level settings kept in UserDefaults (each provider keeps its own).
enum Preferences {
    static let menuBarProviderKey = "menuBarProvider"
    static let showPercentKey = "showMenuBarPercent"
    static let followActiveAppKey = "menuBarFollowsActiveApp"
    static let showCostKey = "showCostEstimate"
    static let menuBarMetricKey = "menuBarMetric"
    static let panelHotKeyKey = "panelHotKey"
    static let followTightestKey = "menuBarFollowsTightest"

    /// Show whichever of Claude and Codex has less left; off unless turned on.
    static var followTightest: Bool { UserDefaults.standard.bool(forKey: followTightestKey) }

    static var menuBarMetric: MenuBarMetric {
        UserDefaults.standard.string(forKey: menuBarMetricKey).flatMap(MenuBarMetric.init) ?? .session
    }

    /// ⌘⌥0 opens the panel; on unless turned off.
    static var panelHotKey: Bool {
        UserDefaults.standard.object(forKey: panelHotKeyKey) as? Bool ?? true
    }

    static var menuBarProvider: MenuBarProvider? {
        get { UserDefaults.standard.string(forKey: menuBarProviderKey).flatMap(MenuBarProvider.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: menuBarProviderKey) }
    }

    /// Show the provider of the frontmost Claude, Codex or More Providers
    /// app (Antigravity); on unless turned off.
    static var followActiveApp: Bool {
        UserDefaults.standard.object(forKey: followActiveAppKey) as? Bool ?? true
    }

    /// Percentage text next to the icon; on unless turned off.
    static var showPercent: Bool {
        UserDefaults.standard.object(forKey: showPercentKey) as? Bool ?? true
    }
}
