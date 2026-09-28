import Foundation
import AgentUI

/// Which provider the menu bar icon follows.
enum MenuBarProvider: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }
    var style: ProviderStyle { self == .claude ? .claude : .codex }
}

/// App-level settings kept in UserDefaults (each provider keeps its own).
enum Preferences {
    static let menuBarProviderKey = "menuBarProvider"
    static let showPercentKey = "showMenuBarPercent"

    static var menuBarProvider: MenuBarProvider? {
        get { UserDefaults.standard.string(forKey: menuBarProviderKey).flatMap(MenuBarProvider.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: menuBarProviderKey) }
    }

    /// Percentage text next to the icon; on unless turned off.
    static var showPercent: Bool {
        UserDefaults.standard.object(forKey: showPercentKey) as? Bool ?? true
    }
}
