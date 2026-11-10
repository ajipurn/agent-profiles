import AppKit
import SwiftUI
import AgentUI
import CodexProfilesUI
import ProvidersCore

/// The status item's panel, OpenUsage-style: estimated cost, provider
/// switcher, the selected provider's usage card, other accounts to switch
/// to, then actions. A borderless window of our own rather than an
/// NSPopover: a popover keeps the size it measured on opening, so content
/// that loads afterwards left its translucent frame showing around ours.
/// Its content is rebuilt each time it opens.
@MainActor
final class StatusPanelController: NSObject {
    private var window: PanelWindow?
    private var host: NSHostingController<StatusPanelView>?
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
    private var activationObserver: Any?
    private var closedAt = Date.distantPast
    private let claude: AppState
    private let codex: AppModel
    private let cost: CostModel
    private let extras: ExtraProvidersModel
    private let status: StatusModel
    private let defaultTab: () -> String
    private let pickTab: (MenuBarProvider) -> Void
    private let openSettings: (SettingsPane) -> Void
    private let switchCodex: (String) -> Void
    private let tab = TabSelection()

    static let width: CGFloat = 340
    /// Gap between the menu bar and the panel.
    private static let gap: CGFloat = 4
    /// Never open shorter than this: a zero-height window is never drawn,
    /// so SwiftUI would never report the real height (1.3.1–1.3.2).
    private static let minHeight: CGFloat = 200

    init(claude: AppState, codex: AppModel, cost: CostModel, extras: ExtraProvidersModel, status: StatusModel,
         defaultTab: @escaping () -> String,
         pickTab: @escaping (MenuBarProvider) -> Void,
         openSettings: @escaping (SettingsPane) -> Void,
         switchCodex: @escaping (String) -> Void) {
        self.claude = claude
        self.codex = codex
        self.cost = cost
        self.extras = extras
        self.status = status
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
        // Pressing the icon makes macOS reactivate the app that was in
        // front, which closes the panel before this click's action arrives.
        // That click meant "close", not "open again" (1.3.3 flickered).
        if Date().timeIntervalSince(closedAt) < 0.4 { return }
        self.button = button
        tab.selected = defaultTab() // always open on the provider the icon shows
        #if DEBUG
        // Screenshot aid: `--tab <id>` opens on that tab.
        if let flag = CommandLine.arguments.firstIndex(of: "--tab"), CommandLine.arguments.indices.contains(flag + 1) {
            tab.selected = CommandLine.arguments[flag + 1]
        }
        #endif
        let host = NSHostingController(rootView: StatusPanelView(
            tab: tab, claude: claude, codex: codex, cost: cost, extras: extras, status: status, actions: actions,
            onHeightChange: { [weak self] height in self?.place(height: height) }))
        host.sizingOptions = [] // place(height:) owns the window size
        // Measured explicitly up front: fittingSize is 0 here, which left
        // 1.3.1–1.3.2 with an invisible, zero-height panel.
        let height = host.sizeThatFits(in: CGSize(width: Self.width, height: 4000)).height
        // A plain container, so the window's size never follows the hosting
        // view's constraints.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: max(height, Self.minHeight)))
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .height]
        container.addSubview(host.view)
        let panel = PanelWindow(contentView: container)
        self.host = host
        window = panel
        place(height: height)
        codex.startLiveUsagePolling()
        claude.refreshUsage()
        cost.refresh()
        extras.refresh()
        status.refresh()
        NSApp.activate(ignoringOtherApps: true) // so the panel takes keys (⌘R, ⌘,, ⌘Q)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        watchForDismissal(panel)
    }

    func close() {
        guard let window else { return }
        closedAt = Date()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        window.orderOut(nil)
        self.window = nil
        host = nil
        button?.highlight(false)
        codex.stopLiveUsagePolling()
    }

    /// Hangs the panel under the status item, its top edge fixed so it grows
    /// and shrinks downward, kept on screen.
    private func place(height: CGFloat) {
        guard let window, let anchor = buttonFrame,
              let screen = button?.window?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var x = anchor.midX - Self.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        let top = anchor.minY - Self.gap
        let height = max(height.rounded(.up), Self.minHeight)
        window.setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
    }

    /// The status item's icon in screen coordinates.
    private var buttonFrame: NSRect? {
        guard let button, let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Clicks in other apps, switching to another app, or Escape close the
    /// panel. Not losing key status: an accessory app is usually inactive
    /// when its status item is clicked, and the panel loses key right after
    /// opening, which closed it before it was ever seen (1.3.1).
    private func watchForDismissal(_ panel: PanelWindow) {
        panel.onCancel = { [weak self] in self?.close() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                // The menu bar delivers a click on our own icon here too.
                // Leave it to the icon's action, which toggles; closing now
                // made that action reopen the panel, so it flickered (1.3.3).
                if self.buttonFrame?.contains(location) == true { return }
                self.close()
            }
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
            select: { [weak self] id in
                guard let self, id != self.tab.selected else { return }
                self.tab.selected = id
                // The menu bar icon (and Settings' "Show usage for") follows
                // the Claude and Codex tabs.
                if let provider = MenuBarProvider(rawValue: id) { self.pickTab(provider) }
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
        case .refreshExtra:
            extras.refresh(force: true)
            status.refresh(force: true)
        case .open(let url): NSWorkspace.shared.open(url)
        case .copyImage(let image):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        case .settings(let pane): openSettings(pane)
        case .quit: NSApp.terminate(nil)
        }
    }
}

enum PanelAction {
    case switchClaude(String), switchCodex(String), switchCLI(String?)
    case setUpClaude, newClaudeProfile, refreshClaude
    case refreshCodex, addCodex, cancelCodexLogin, saveCodex
    case refreshExtra, open(URL), copyImage(NSImage)
    case settings(SettingsPane), quit

    var closesPanel: Bool {
        switch self {
        case .refreshClaude, .refreshCodex, .refreshExtra, .switchCLI, .cancelCodexLogin, .copyImage: false
        default: true
        }
    }
}

struct PanelActions {
    let select: (String) -> Void
    let run: (PanelAction) -> Void
}

/// The panel's tab: "claude", "codex", an extra provider's id, or "overview".
@MainActor
final class TabSelection: ObservableObject {
    @Published var selected = "claude"
}

struct StatusPanelView: View {
    @ObservedObject var tab: TabSelection
    @ObservedObject var claude: AppState
    let codex: AppModel // @Observable: reading it in `body` keeps it live
    @ObservedObject var cost: CostModel
    @ObservedObject var extras: ExtraProvidersModel
    @ObservedObject var status: StatusModel
    @AppStorage(Preferences.showCostKey) private var showCost = true
    @AppStorage(UsageDisplay.sortByHeadroomKey) private var sortByHeadroom = true
    @AppStorage(UsageDisplay.hidePersonalKey) private var hidePersonal = false
    @AppStorage(UsageDisplay.showsUsedKey) private var showsUsed = false
    @AppStorage(UsageDisplay.resetClockKey) private var resetAsClock = false
    let actions: PanelActions
    /// The window follows the content as data loads or the tab changes.
    let onHeightChange: (CGFloat) -> Void

    static let overviewID = "overview"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showCost {
                CostCardView(periods: cost.periods, days: cost.days, isLoading: cost.summary == nil, note: cost.note)
            }
            ProviderSwitcherView(tiles: tiles, selected: selectedID, onSelect: actions.select)

            if selectedID == Self.overviewID {
                OverviewView(rows: overviewRows, onSelect: actions.select)
            } else if let extra = extras.active.first(where: { $0.id == selectedID }) {
                extraBody(extra)
            } else {
                providerBody(selectedID == "codex" ? .codex : .claude)
            }

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
            Color.clear
                .onAppear { report(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in report(height) }
        })
    }

    private func report(_ height: CGFloat) {
        if height > 1 { onHeightChange(height) }
    }

    // MARK: Tabs

    /// The selected tab, falling back to Claude when it went away (an extra
    /// provider turned off).
    private var selectedID: String {
        tiles.contains { $0.id == tab.selected } ? tab.selected : "claude"
    }

    private var tiles: [ProviderSwitcherView.Tile] {
        var tiles: [ProviderSwitcherView.Tile] = []
        if !extras.active.isEmpty {
            tiles.append(.init(style: ProviderStyle(id: Self.overviewID, name: "Overview", symbol: "square.grid.2x2",
                                                    accent: .accentColor),
                               remaining: nil, hasIncident: false))
        }
        tiles.append(.init(style: .claude, remaining: claude.cardModel.sessionRemaining,
                           hasIncident: status.incidents["claude"] != nil))
        tiles.append(.init(style: .codex, remaining: codex.cardModel.sessionRemaining,
                           hasIncident: status.incidents["codex"] != nil))
        for provider in extras.active {
            tiles.append(.init(style: ExtraProvidersModel.style(provider), remaining: extras.primaryRemaining(provider.id).0,
                               hasIncident: status.incidents[provider.id] != nil))
        }
        return tiles
    }

    // MARK: Cards

    private var claudeCard: UsageCardModel {
        var card = claude.cardModel
        card.incident = status.incident(for: "claude")
        card.dashboardURL = URL(string: "https://claude.ai/settings/usage")
        return card
    }

    private var codexCard: UsageCardModel {
        var card = codex.cardModel
        card.incident = status.incident(for: "codex")
        card.dashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")
        return card
    }

    private func extraCard(_ provider: any UsageProvider) -> UsageCardModel {
        var card = extras.cardModel(provider)
        card.incident = status.incident(for: provider.id)
        return card
    }

    @ViewBuilder
    private func providerBody(_ provider: MenuBarProvider) -> some View {
        let card = provider == .claude ? claudeCard : codexCard
        VStack(alignment: .leading, spacing: 14) {
            UsageCardView(model: card)
            accounts(provider)
            if provider == .claude, claude.cliSetUp, claude.mode == .ready {
                cliPicker
            }
            actionRow(provider, card: card)
        }
    }

    private func extraBody(_ provider: any UsageProvider) -> some View {
        let card = extraCard(provider)
        return VStack(alignment: .leading, spacing: 14) {
            UsageCardView(model: card)
            HStack(spacing: 8) {
                PanelActionButton("Refresh", symbol: "arrow.clockwise") { actions.run(.refreshExtra) }
                    .keyboardShortcut("r")
                if let url = provider.dashboardURL {
                    PanelActionButton("Dashboard", symbol: "chart.bar") { actions.run(.open(url)) }
                }
                PanelActionButton("Copy Image", symbol: "photo.on.rectangle") { copyImage(card) }
                PanelActionButton("Manage", symbol: "slider.horizontal.3") { actions.run(.settings(.providers)) }
            }
        }
    }

    @ViewBuilder
    private func accounts(_ provider: MenuBarProvider) -> some View {
        let list = sorted(provider == .claude ? claude.menuAccounts : codex.menuAccounts)
        let enabled = provider == .claude ? claude.canSwitchDesktop : codex.canSwitch
        let tint = provider == .claude ? ProviderStyle.claude.accent : ProviderStyle.codex.accent
        if !list.isEmpty {
            AccountListView(accounts: list, tint: tint, isEnabled: enabled) { account in
                actions.run(provider == .claude ? .switchClaude(account.id) : .switchCodex(account.id))
            }
        }
    }

    /// Most usable first (the tighter of the two windows), when Settings
    /// says so; accounts without numbers last, in their saved order.
    private func sorted(_ list: [UsageAccount]) -> [UsageAccount] {
        guard sortByHeadroom else { return list }
        return list.enumerated().sorted { lhs, rhs in
            switch (lhs.element.usable, rhs.element.usable) {
            case let (l?, r?) where l != r: l > r
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.offset < rhs.offset
            }
        }.map(\.element)
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
    private func actionRow(_ provider: MenuBarProvider, card: UsageCardModel) -> some View {
        HStack(spacing: 8) {
            switch provider {
            case .claude:
                if claude.mode == .needsSetup {
                    PanelActionButton("Set Up", symbol: "person.crop.circle.badge.plus") { actions.run(.setUpClaude) }
                } else {
                    PanelActionButton("New Profile", symbol: "person.badge.plus") { actions.run(.newClaudeProfile) }
                }
                PanelActionButton("Refresh", symbol: "arrow.clockwise") { actions.run(.refreshClaude) }
                    .keyboardShortcut("r")
                PanelActionButton("Copy Image", symbol: "photo.on.rectangle") { copyImage(card) }
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
                PanelActionButton("Refresh", symbol: "arrow.clockwise") { actions.run(.refreshCodex) }
                    .keyboardShortcut("r")
                if !codex.needsSave {
                    PanelActionButton("Copy Image", symbol: "photo.on.rectangle") { copyImage(card) }
                }
                PanelActionButton("Manage", symbol: "slider.horizontal.3") { actions.run(.settings(.codex)) }
            }
        }
    }

    // MARK: Overview

    /// Every provider at a glance, the one closest to running out first.
    private var overviewRows: [OverviewView.Row] {
        var rows: [OverviewView.Row] = [
            .init(id: "claude", card: claudeCard),
            .init(id: "codex", card: codexCard),
        ]
        rows += extras.active.map { .init(id: $0.id, card: extraCard($0)) }
        return rows.enumerated().sorted { lhs, rhs in
            let l = lhs.element.tightest ?? 101, r = rhs.element.tightest ?? 101
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: Snapshot

    /// The card as a PNG on the clipboard, email addresses masked.
    private func copyImage(_ card: UsageCardModel) {
        var card = card
        card.account = card.account.map { UsageFormat.personal($0, hide: true) }
        card.notice = nil
        let view = UsageCardView(model: card)
            .padding(16)
            .frame(width: StatusPanelController.width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage { actions.run(.copyImage(image)) }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Text("Agent Profiles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            Spacer()
            PanelIconButton(showsUsed ? "Show what's left" : "Show what's used",
                            symbol: showsUsed ? "chart.bar.fill" : "chart.bar") { showsUsed.toggle() }
            PanelIconButton(hidePersonal ? "Show email addresses" : "Hide email addresses",
                            symbol: hidePersonal ? "eye.slash" : "eye") { hidePersonal.toggle() }
            PanelIconButton("Settings (⌘,)", symbol: "gearshape") { actions.run(.settings(.general)) }
                .keyboardShortcut(",")
            PanelIconButton("Quit Agent Profiles (⌘Q)", symbol: "power") { actions.run(.quit) }
                .keyboardShortcut("q")
        }
        .padding(.top, 2)
    }
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

