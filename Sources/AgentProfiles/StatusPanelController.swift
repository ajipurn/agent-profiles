import AppKit
import SwiftUI
import AgentUI
import CodexProfilesUI

/// The status item's popover, OpenUsage-style: estimated cost, provider
/// switcher, the selected provider's usage card, other accounts to switch
/// to, then actions. Its content is rebuilt each time it opens.
@MainActor
final class StatusPanelController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let claude: AppState
    private let codex: AppModel
    private let cost: CostModel
    private let defaultTab: () -> MenuBarProvider
    private let pickTab: (MenuBarProvider) -> Void
    private let openSettings: (SettingsPane) -> Void
    private let switchCodex: (String) -> Void
    private let tab = TabSelection()

    static let width: CGFloat = 340

    init(claude: AppState, codex: AppModel, cost: CostModel,
         defaultTab: @escaping () -> MenuBarProvider,
         pickTab: @escaping (MenuBarProvider) -> Void,
         openSettings: @escaping (SettingsPane) -> Void,
         switchCodex: @escaping (String) -> Void) {
        self.claude = claude
        self.codex = codex
        self.cost = cost
        self.defaultTab = defaultTab
        self.pickTab = pickTab
        self.openSettings = openSettings
        self.switchCodex = switchCodex
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.hasFullSizeContent = true // our solid background reaches the edges
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        tab.selected = defaultTab() // always open on the provider the icon shows
        let host = NSHostingController(rootView: StatusPanelView(
            tab: tab, claude: claude, codex: codex, cost: cost, actions: actions))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        codex.startLiveUsagePolling()
        claude.refreshUsage()
        cost.refresh()
        NSApp.activate(ignoringOtherApps: true) // so the panel takes keys (⌘R, ⌘,, ⌘Q)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        codex.stopLiveUsagePolling()
        popover.contentViewController = nil
    }

    private var actions: PanelActions {
        PanelActions(
            select: { [weak self] provider in
                guard let self, provider != self.tab.selected else { return }
                self.tab.selected = provider
                // The menu bar icon (and Settings' "Show usage for") follows the tab.
                self.pickTab(provider)
            },
            run: { [weak self] action in
                guard let self else { return }
                // Anything that opens a window or dialog needs the panel gone first.
                if action.closesPanel { self.popover.performClose(nil) }
                self.perform(action)
            })
    }

    private func perform(_ action: PanelAction) {
        switch action {
        case .switchClaude(let name): claude.switchTo(name)
        case .switchCodex(let id): switchCodex(id)
        case .switchCLI(let name): claude.switchCLI(name)
        case .setUpClaude: claude.setUpProfiles()
        case .newClaudeProfile: claude.newProfile()
        case .refreshClaude:
            claude.refreshUsage()
            cost.refresh(force: true)
        case .refreshCodex:
            codex.refreshUsage(force: true)
            cost.refresh(force: true)
        case .addCodex:
            codex.beginAdd()
            // Unsaved current login: Settings asks for its name first.
            if codex.isEditing { openSettings(.codex) }
        case .cancelCodexLogin: codex.cancelLogin()
        case .saveCodex:
            codex.beginSave()
            openSettings(.codex)
        case .settings(let pane): openSettings(pane)
        case .quit: NSApp.terminate(nil)
        }
    }
}

enum PanelAction {
    case switchClaude(String), switchCodex(String), switchCLI(String?)
    case setUpClaude, newClaudeProfile, refreshClaude
    case refreshCodex, addCodex, cancelCodexLogin, saveCodex
    case settings(SettingsPane), quit

    var closesPanel: Bool {
        switch self {
        case .refreshClaude, .refreshCodex, .switchCLI, .cancelCodexLogin: false
        default: true
        }
    }
}

struct PanelActions {
    let select: (MenuBarProvider) -> Void
    let run: (PanelAction) -> Void
}

@MainActor
final class TabSelection: ObservableObject {
    @Published var selected: MenuBarProvider = .claude
}

private struct StatusPanelView: View {
    @ObservedObject var tab: TabSelection
    @ObservedObject var claude: AppState
    let codex: AppModel // @Observable: reading it in `body` keeps it live
    @ObservedObject var cost: CostModel
    @AppStorage(Preferences.showCostKey) private var showCost = true
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showCost {
                CostCardView(periods: cost.periods, isLoading: cost.summary == nil, note: cost.note)
            }
            ProviderSwitcherView(
                tiles: [
                    .init(style: .claude, remaining: claude.cardModel.sessionRemaining),
                    .init(style: .codex, remaining: codex.cardModel.sessionRemaining),
                ],
                selected: tab.selected.style.name,
                onSelect: { name in actions.select(name == ProviderStyle.claude.name ? .claude : .codex) })

            providerBody(tab.selected)

            footer
        }
        .padding(14)
        .padding(.top, 4)
        .frame(width: StatusPanelController.width)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    @ViewBuilder
    private func providerBody(_ provider: MenuBarProvider) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            UsageCardView(model: provider == .claude ? claude.cardModel : codex.cardModel)
            accounts(provider)
            if provider == .claude, claude.cliSetUp, claude.mode == .ready {
                cliPicker
            }
            actionRow(provider)
        }
    }

    @ViewBuilder
    private func accounts(_ provider: MenuBarProvider) -> some View {
        let list = provider == .claude ? claude.menuAccounts : codex.menuAccounts
        let enabled = provider == .claude ? claude.canSwitchDesktop : codex.canSwitch
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Switch Account")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(list) { account in
                        AccountRowView(account: account, isEnabled: enabled) {
                            actions.run(provider == .claude ? .switchClaude(account.id) : .switchCodex(account.id))
                        }
                    }
                }
                .padding(4)
                .panelCard()
            }
        }
    }

    /// Which profile `claude` in the terminal uses; switching is instant.
    private var cliPicker: some View {
        let names: [String?] = (claude.cliDefaultHidden ? [] : [nil]) + claude.allProfiles.map(Optional.some)
        return HStack {
            Label("Claude Code", systemImage: "terminal")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Menu {
                ForEach(names, id: \.self) { name in
                    Button {
                        actions.run(.switchCLI(name))
                    } label: {
                        if name == claude.activeCLIProfile {
                            Label(name ?? "Default (~/.claude)", systemImage: "checkmark")
                        } else {
                            Text(name ?? "Default (~/.claude)")
                        }
                    }
                }
            } label: {
                Text(claude.activeCLIProfile ?? "Default")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .panelCard()
    }

    @ViewBuilder
    private func actionRow(_ provider: MenuBarProvider) -> some View {
        HStack(spacing: 8) {
            switch provider {
            case .claude:
                if claude.mode == .needsSetup {
                    PanelActionButton("Set Up", symbol: "person.crop.circle.badge.plus") { actions.run(.setUpClaude) }
                } else {
                    PanelActionButton("New Profile", symbol: "person.badge.plus") { actions.run(.newClaudeProfile) }
                }
                PanelActionButton("Refresh", symbol: "arrow.clockwise",) { actions.run(.refreshClaude) }
                    .keyboardShortcut("r")
                PanelActionButton("Manage", symbol: "slider.horizontal.3") { actions.run(.settings(.claude)) }
            case .codex:
                if codex.awaitingLogin {
                    PanelActionButton("Cancel Sign-in", symbol: "xmark.circle") { actions.run(.cancelCodexLogin) }
                } else {
                    PanelActionButton("Add Account", symbol: "person.badge.plus") { actions.run(.addCodex) }
                        .disabled(!codex.canSwitch)
                }
                if codex.needsSave {
                    PanelActionButton("Save", symbol: "square.and.arrow.down") { actions.run(.saveCodex) }
                }
                PanelActionButton("Refresh", symbol: "arrow.clockwise",) { actions.run(.refreshCodex) }
                    .keyboardShortcut("r")
                PanelActionButton("Manage", symbol: "slider.horizontal.3") { actions.run(.settings(.codex)) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Text("Agent Profiles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            Spacer()
            PanelIconButton("Settings (⌘,)", symbol: "gearshape") { actions.run(.settings(.general)) }
                .keyboardShortcut(",")
            PanelIconButton("About Agent Profiles", symbol: "info.circle") { actions.run(.settings(.about)) }
            PanelIconButton("Quit Agent Profiles (⌘Q)", symbol: "power") { actions.run(.quit) }
                .keyboardShortcut("q")
        }
        .padding(.top, 2)
    }
}
