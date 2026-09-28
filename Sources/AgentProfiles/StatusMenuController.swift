import AppKit
import SwiftUI
import AgentUI
import CodexProfilesUI

/// The status item's menu, CodexBar-style: provider tabs, the selected
/// provider's usage card, other accounts to switch to, then actions.
/// Rebuilt each time it opens; the card itself updates live while open.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    private let claude: AppState
    private let codex: AppModel
    private let defaultTab: () -> MenuBarProvider
    private let openSettings: (SettingsPane) -> Void
    private let switchCodex: (String) -> Void
    private let tab = TabSelection()

    private static let width: CGFloat = 300

    init(claude: AppState, codex: AppModel,
         defaultTab: @escaping () -> MenuBarProvider,
         openSettings: @escaping (SettingsPane) -> Void,
         switchCodex: @escaping (String) -> Void) {
        self.claude = claude
        self.codex = codex
        self.defaultTab = defaultTab
        self.openSettings = openSettings
        self.switchCodex = switchCodex
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        tab.selected = defaultTab() // always open on the provider the icon shows
        menu.removeAllItems()
        menu.addItem(switcherItem())
        addBody()
    }

    func menuWillOpen(_ menu: NSMenu) {
        codex.startLiveUsagePolling()
        claude.refreshUsage()
    }

    func menuDidClose(_ menu: NSMenu) {
        codex.stopLiveUsagePolling()
    }

    // MARK: Building

    private func select(_ provider: MenuBarProvider) {
        guard provider != tab.selected else { return }
        tab.selected = provider
        // Keep the switcher row (it is handling this click); replace the rest.
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }
        addBody()
    }

    private func switcherItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuItemHostView(width: Self.width, highlightsOnHover: false, onClick: { [weak self] point in
            self?.select(point.x < Self.width / 2 ? .claude : .codex)
        }) { _ in
            SwitcherHost(tab: tab, claude: claude, codex: codex)
        }
        return item
    }

    private func addBody() {
        let provider = tab.selected
        menu.addItem(.separator())

        let card = NSMenuItem()
        card.isEnabled = false
        card.view = MenuItemHostView(width: Self.width) { [claude, codex] _ in
            switch provider {
            case .claude: ClaudeCardHost(state: claude)
            case .codex: CodexCardHost(model: codex)
            }
        }
        menu.addItem(card)

        let accounts = provider == .claude ? claude.menuAccounts : codex.menuAccounts
        let canSwitch = provider == .claude ? claude.canSwitchDesktop : codex.canSwitch
        if !accounts.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Switch Account"))
            for account in accounts {
                menu.addItem(accountItem(account, provider: provider, enabled: canSwitch))
            }
        }
        if provider == .claude, claude.cliSetUp, claude.mode == .ready {
            menu.addItem(cliItem())
        }

        menu.addItem(.separator())
        for item in actions(for: provider) { menu.addItem(item) }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Settings…", key: ",") { [weak self] in self?.openSettings(.general) })
        menu.addItem(ActionMenuItem("About Agent Profiles") { [weak self] in self?.openSettings(.about) })
        menu.addItem(ActionMenuItem("Quit Agent Profiles", key: "q") { NSApp.terminate(nil) })
    }

    private func accountItem(_ account: UsageAccount, provider: MenuBarProvider, enabled: Bool) -> NSMenuItem {
        let perform: () -> Void = { [claude, switchCodex] in
            switch provider {
            case .claude: claude.switchTo(account.id)
            case .codex: switchCodex(account.id)
            }
        }
        let item = ActionMenuItem(account.title, handler: perform)
        item.isEnabled = enabled
        item.view = MenuItemHostView(width: Self.width, onClick: { [weak menu] _ in
            menu?.cancelTracking()
            perform()
        }) { highlight in
            AccountRowView(account: account, tint: provider.style.accent, isEnabled: enabled, highlight: highlight)
        }
        return item
    }

    /// Which profile `claude` in the terminal uses; switching is instant.
    private func cliItem() -> NSMenuItem {
        let item = ActionMenuItem("Claude Code Profile", symbol: "terminal") {}
        item.action = nil
        let submenu = NSMenu()
        var names: [String?] = claude.cliDefaultHidden ? [] : [nil]
        names += claude.allProfiles.map(Optional.some)
        for name in names {
            let entry = ActionMenuItem(name ?? "Default (~/.claude)") { [claude] in claude.switchCLI(name) }
            entry.state = name == claude.activeCLIProfile ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func actions(for provider: MenuBarProvider) -> [NSMenuItem] {
        switch provider {
        case .claude:
            var items: [NSMenuItem] = []
            if claude.mode == .needsSetup {
                items.append(ActionMenuItem("Set Up Profiles…", symbol: "person.crop.circle.badge.plus") { [claude] in
                    claude.setUpProfiles()
                })
            } else {
                items.append(ActionMenuItem("New Profile…", symbol: "person.badge.plus") { [claude] in
                    claude.newProfile()
                })
            }
            items.append(ActionMenuItem("Refresh Usage", key: "r", symbol: "arrow.clockwise") { [claude] in
                claude.refreshUsage()
            })
            items.append(ActionMenuItem("Manage Profiles…", symbol: "slider.horizontal.3") { [weak self] in
                self?.openSettings(.claude)
            })
            return items
        case .codex:
            var items: [NSMenuItem] = []
            if codex.awaitingLogin {
                items.append(ActionMenuItem("Cancel Sign-in", symbol: "xmark.circle") { [codex] in
                    codex.cancelLogin()
                })
            } else {
                let add = ActionMenuItem("Add Account…", symbol: "person.badge.plus") { [weak self, codex] in
                    codex.beginAdd()
                    // Unsaved current login: Settings asks for its name first.
                    if codex.isEditing { self?.openSettings(.codex) }
                }
                add.isEnabled = codex.canSwitch
                items.append(add)
            }
            if codex.needsSave {
                items.append(ActionMenuItem("Save Current Account…", symbol: "square.and.arrow.down") { [weak self, codex] in
                    codex.beginSave()
                    self?.openSettings(.codex)
                })
            }
            items.append(ActionMenuItem("Refresh Usage", key: "r", symbol: "arrow.clockwise") { [codex] in
                codex.refreshUsage(force: true)
            })
            items.append(ActionMenuItem("Manage Accounts…", symbol: "slider.horizontal.3") { [weak self] in
                self?.openSettings(.codex)
            })
            return items
        }
    }
}

@MainActor
private final class TabSelection: ObservableObject {
    @Published var selected: MenuBarProvider = .claude
}

private struct SwitcherHost: View {
    @ObservedObject var tab: TabSelection
    @ObservedObject var claude: AppState
    let codex: AppModel

    var body: some View {
        ProviderSwitcherView(
            tiles: [
                .init(style: .claude, remaining: claude.cardModel.sessionRemaining),
                .init(style: .codex, remaining: codex.cardModel.sessionRemaining),
            ],
            selected: tab.selected.style.name)
    }
}

private struct ClaudeCardHost: View {
    @ObservedObject var state: AppState

    var body: some View {
        UsageCardView(model: state.cardModel)
    }
}

/// AppModel is @Observable, so reading it in `body` is enough to stay live.
private struct CodexCardHost: View {
    let model: AppModel

    var body: some View {
        UsageCardView(model: model.cardModel)
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        if let symbol, let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            // Without an explicit size the menu drops the symbol.
            icon.isTemplate = true
            icon.size = NSSize(width: 16, height: 16)
            image = icon
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
