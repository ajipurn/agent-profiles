import AppKit
import SwiftUI
import AgentUI
import CodexProfilesUI

/// The status item's panel, OpenUsage-style: estimated cost, provider
/// switcher, the selected provider's usage card, other accounts to switch
/// to, then actions. A borderless window of our own rather than an
/// NSPopover: a popover keeps the size it measured on opening, so content
/// that loads afterwards left its translucent frame showing around ours.
/// Its content is rebuilt each time it opens.
@MainActor
final class StatusPanelController: NSObject {
    private var window: PanelWindow?
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
    private var activationObserver: Any?
    private let claude: AppState
    private let codex: AppModel
    private let cost: CostModel
    private let defaultTab: () -> MenuBarProvider
    private let pickTab: (MenuBarProvider) -> Void
    private let openSettings: (SettingsPane) -> Void
    private let switchCodex: (String) -> Void
    private let tab = TabSelection()

    static let width: CGFloat = 340
    /// Gap between the menu bar and the panel.
    private static let gap: CGFloat = 4

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
    }

    var isShown: Bool { window != nil }

    func toggle(from button: NSStatusBarButton) {
        if isShown {
            close()
            return
        }
        self.button = button
        tab.selected = defaultTab() // always open on the provider the icon shows
        let host = NSHostingView(rootView: StatusPanelView(
            tab: tab, claude: claude, codex: codex, cost: cost, actions: actions,
            onResize: { [weak self] size in self?.place(height: size.height) }))
        host.sizingOptions = [] // place(height:) owns the window size
        let panel = PanelWindow(contentView: host)
        window = panel
        place(height: host.fittingSize.height)
        codex.startLiveUsagePolling()
        claude.refreshUsage()
        cost.refresh()
        NSApp.activate(ignoringOtherApps: true) // so the panel takes keys (⌘R, ⌘,, ⌘Q)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        watchForDismissal(panel)
    }

    func close() {
        guard let window else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        window.orderOut(nil)
        self.window = nil
        button?.highlight(false)
        codex.stopLiveUsagePolling()
    }

    /// Hangs the panel under the status item, its top edge fixed so it grows
    /// and shrinks downward, kept on screen.
    private func place(height: CGFloat) {
        guard let window, let button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        var x = anchor.midX - Self.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        let top = anchor.minY - Self.gap
        window.setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
    }

    /// Clicks in other apps, switching to another app, or Escape close the
    /// panel. Not losing key status: an accessory app is usually inactive
    /// when its status item is clicked, and the panel loses key right after
    /// opening, which closed it before it was ever seen (1.3.1).
    private func watchForDismissal(_ panel: PanelWindow) {
        panel.onCancel = { [weak self] in self?.close() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            monitors.append(global)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ownPID else { return }
            Task { @MainActor in self?.close() }
        }
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
                if action.closesPanel { self.close() }
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
    /// The panel window follows the content's height.
    let onResize: (CGSize) -> Void

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
        .frame(width: StatusPanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: PanelWindow.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PanelWindow.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: PanelWindow.cornerRadius, style: .continuous))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { size in onResize(size) }
        .frame(maxHeight: .infinity, alignment: .top)
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

private struct PanelSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Borderless, transparent window holding the panel; the rounded card and
/// its shadow are all there is to see.
final class PanelWindow: NSPanel {
    static let cornerRadius: CGFloat = 14
    var onCancel: (() -> Void)?

    init(contentView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: StatusPanelController.width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        invalidateShadow() // the shadow follows the rounded card, not the frame
    }
}
