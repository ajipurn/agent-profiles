import SwiftUI
import AppKit
import Observation
import UserNotifications
import AgentUI
import ClaudeProfilesCore
import CodexProfilesCore
import CodexProfilesUI

@main
struct AgentProfilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // All real UI is AppKit-owned: the status item, its menu and the
        // Settings window.
        Settings { EmptyView() }
    }
}

// MARK: - App delegate

/// Owns the status item and its menu (CodexBar-style) for both providers:
/// Claude (Desktop and CLI profiles, from Claude Profiles) and Codex (from
/// Codex Profiles). The icon follows the provider picked in Settings, or the
/// frontmost Claude/Codex app when that is turned on.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// `--demo`: sample accounts in throwaway directories. Nothing touches the
    /// real Claude or Codex setup, so it is safe to run next to the old apps.
    let isDemo = CommandLine.arguments.contains("--demo")

    // Created once launching is known to be safe (see LegacyAppGuard):
    // AppState's init already works on the profile folders.
    private(set) var state: AppState!
    private(set) var codex: AppModel!
    private var updates: UpdateController!
    private var cost: CostModel!
    private var claudeDemoHome: URL?

    private var statusItem: NSStatusItem!
    private var panel: StatusPanelController!
    private var settingsWindow: NSWindow?
    private var cancellables: [Any] = []
    private var wasCompletingLogin = false
    /// A Codex switch started here (menu, hotkey, URL, notification), reported
    /// by notification once it finishes.
    private var pendingCodexSwitch: String?
    /// Codex session windows already alerted about (account + reset time).
    private var codexLowNotified: Set<String> = []
    /// Provider of the last Claude or Codex app brought to the front; other
    /// apps leave it alone so the icon doesn't flip back and forth.
    private var activeAppProvider: MenuBarProvider?
    /// Picking a provider (menu tab or Settings) overrides the detected app
    /// until the next Claude/Codex activation.
    private var lastPickedProvider: MenuBarProvider?

    /// What the status item and the menu's opening tab show.
    private var displayedProvider: MenuBarProvider {
        (Preferences.followActiveApp ? activeAppProvider : nil) ?? Preferences.menuBarProvider ?? .claude
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard isDemo || LegacyAppGuard.clearToLaunch() else {
            NSApp.terminate(nil)
            return
        }

        if isDemo {
            let home = ClaudeDemo.makeHome()
            claudeDemoHome = home
            state = AppState(home: home, demo: true)
        } else {
            state = AppState()
        }
        codex = AppModel(demo: isDemo)
        updates = UpdateController(enabled: !isDemo) { [weak self] in
            self?.canRelaunchForUpdate ?? false
        }
        codex.updater = updates
        if Preferences.menuBarProvider == nil {
            // First run: follow whichever provider is actually in use.
            Preferences.menuBarProvider = state.mode == .ready || codex.live?.file == nil ? .claude : .codex
        }

        state.openWindowHandler = { [weak self] in self?.showSettings(.claude) }
        // Same bundle guard as Notifier: the notification center throws
        // without a real .app bundle (`swift run`).
        if Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
        HotKeys.install { [weak self] group, index in
            guard let self else { return }
            switch group {
            case .claude:
                guard self.state.canSwitchDesktop, index < self.state.allProfiles.count else { return }
                let name = self.state.allProfiles[index]
                if name != self.state.activeProfile { self.state.switchTo(name) }
            case .codex:
                let ids = self.codex.hotkeyAccountIDs
                guard index < ids.count else { return }
                self.switchCodex(ids[index])
            }
        }

        // Start the first log scan now so the panel opens with numbers.
        cost = CostModel(home: claudeDemoHome ?? FileManager.default.homeDirectoryForCurrentUser)
        cost.refresh()
        panel = StatusPanelController(
            claude: state, codex: codex, cost: cost,
            defaultTab: { [weak self] in self?.displayedProvider ?? .claude },
            pickTab: { [weak self] provider in
                // Also overrides the detected app, even if the preference
                // already matched.
                self?.activeAppProvider = nil
                Preferences.menuBarProvider = provider
                self?.updateStatusItem()
            },
            openSettings: { [weak self] pane in self?.showSettings(pane) },
            switchCodex: { [weak self] id in self?.switchCodex(id) })
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "dev.aji.AgentProfiles.status"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.imagePosition = .imageLeading
        lastPickedProvider = Preferences.menuBarProvider
        activeAppProvider = MenuBarProvider(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        updateStatusItem()

        cancellables.append(state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Async so the @Published values have actually been written.
                DispatchQueue.main.async { self?.updateStatusItem() }
            })
        cancellables.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Preferences.menuBarProvider != self.lastPickedProvider {
                    self.lastPickedProvider = Preferences.menuBarProvider
                    self.activeAppProvider = nil
                }
                self.updateStatusItem()
            }
        })
        cancellables.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let provider = MenuBarProvider(frontmostBundleID: app?.bundleIdentifier) else { return }
            Task { @MainActor in
                guard let self, self.activeAppProvider != provider else { return }
                self.activeAppProvider = provider
                self.updateStatusItem()
            }
        })
        observeCodex()

        if isDemo { showSettings(.general) }
        #if DEBUG
        // Screenshot aids: `--settings <pane>` opens a Settings pane,
        // `--open-menu` opens the menu right after launch.
        if let flag = CommandLine.arguments.firstIndex(of: "--settings"),
           CommandLine.arguments.indices.contains(flag + 1),
           let pane = SettingsPane(rawValue: CommandLine.arguments[flag + 1]) {
            showSettings(pane)
        }
        if CommandLine.arguments.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        codex?.prepareForTermination()
        if let claudeDemoHome { try? FileManager.default.removeItem(at: claudeDemoHome) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, state != nil { showSettings(nil) }
        return true
    }

    /// Sparkle may only relaunch while no account operation is in flight.
    private var canRelaunchForUpdate: Bool {
        !state.isSwitching && !codex.isBusy && !codex.pendingNewLogin
    }

    /// The Codex model is @Observable, so there is no objectWillChange to
    /// subscribe to: track what the app reacts to and re-arm after each change.
    private func observeCodex() {
        withObservationTracking {
            _ = codex.cardModel
            _ = codex.isBusy
            _ = codex.pendingNewLogin
            _ = codex.isCompletingLogin
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A finished Terminal sign-in needs a name, asked for in Settings.
                if self.codex.isCompletingLogin, !self.wasCompletingLogin { self.showSettings(.codex) }
                self.wasCompletingLogin = self.codex.isCompletingLogin
                self.reportCodexSwitch()
                self.notifyIfCodexNearlyOut()
                self.updateStatusItem()
                self.observeCodex()
            }
        }
    }

    // MARK: Codex switching and alerts

    /// Every Codex switch the app starts goes through here, so its outcome
    /// can be reported: the menu is closed by then and Settings may be too.
    private func switchCodex(_ accountID: String) {
        guard accountID != codex.activeAccountID, codex.canSwitch else { return }
        pendingCodexSwitch = accountID
        codex.switchTo(accountID: accountID)
    }

    private func reportCodexSwitch() {
        guard let pending = pendingCodexSwitch, !codex.isBusy else { return }
        pendingCodexSwitch = nil
        let name = codex.accountName(pending) ?? "the account"
        if codex.activeAccountID == pending {
            Notifier.post("Codex: switched to \(name)",
                          codex.restartsChatGPT ? "" : "Restart ChatGPT to use it there.")
        } else if let error = codex.lastError {
            Notifier.post("Codex switch failed", error)
        }
    }

    /// Once per session window: the active Codex account has 10% or less
    /// left. Suggests the saved account with the most left, if it is well
    /// clear; clicking the notification switches to it.
    private func notifyIfCodexNearlyOut() {
        guard let active = codex.activeAccountID,
              let session = codex.cardModel.limits.first(where: { $0.title == "Session" }),
              let remaining = session.remaining, remaining <= 10,
              let resetsAt = session.resetsAt, resetsAt > Date()
        else { return }
        // Codex reports "resets after N seconds", so the time drifts a little
        // between fetches; ten-minute buckets keep it one window.
        let key = "\(active)-\(Int(resetsAt.timeIntervalSince1970 / 600))"
        guard codexLowNotified.insert(key).inserted else { return }
        let name = codex.accountName(active) ?? "Codex"
        let resets = RelativeDateTimeFormatter().localizedString(for: resetsAt, relativeTo: Date())
        let best = codex.menuAccounts
            .filter { ($0.remaining ?? 0) > 40 }
            .max { ($0.remaining ?? 0) < ($1.remaining ?? 0) }
        if let best {
            Notifier.post("Codex: \(name) is nearly out — \(UsageFormat.percent(remaining)) of session left",
                          "Resets \(resets). Click to switch to \(best.title) (\(UsageFormat.percent(best.remaining)) left).",
                          userInfo: ["switchCodex": best.id])
        } else {
            Notifier.post("Codex: \(name) is nearly out — \(UsageFormat.percent(remaining)) of session left",
                          "Resets \(resets).")
        }
    }

    // MARK: URL scheme

    /// Scripting hook (Raycast, Alfred, shell):
    /// - `agentprofiles://claude/<name>` switches Claude Desktop,
    /// - `agentprofiles://claude-cli/<name>` the Claude Code profile
    ///   (`Default` = the plain ~/.claude account),
    /// - `agentprofiles://codex/<name>` Codex (name, label or email),
    /// - `agentprofiles://open[/<pane>]` opens Settings.
    /// Claude Profiles' `claudeprofiles://switch|switch-cli|open` still work.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard state != nil else { return }
        for url in urls {
            let name = url.pathComponents.count > 1 ? url.pathComponents[1] : nil
            let route: String?
            switch (url.scheme, url.host) {
            case ("agentprofiles", let host): route = host
            case ("claudeprofiles", "switch"): route = "claude"
            case ("claudeprofiles", "switch-cli"): route = "claude-cli"
            case ("claudeprofiles", "open"): route = "open"
            default: route = nil
            }
            switch route {
            case "open":
                showSettings(name.flatMap(SettingsPane.init) ?? (url.scheme == "claudeprofiles" ? .claude : .general))
            case "claude":
                guard let name, state.allProfiles.contains(name) else {
                    Notifier.post("Unknown profile", "No Claude profile named “\(name ?? "?")”.")
                    continue
                }
                if name != state.activeProfile { state.switchTo(name) }
            case "claude-cli":
                guard let name else { continue }
                if name == "Default" {
                    state.switchCLI(nil)
                } else if state.allProfiles.contains(name) {
                    state.switchCLI(name)
                } else {
                    Notifier.post("Unknown profile", "No Claude profile named “\(name)”.")
                }
            case "codex":
                guard let name, let id = codex.accountID(matching: name) else {
                    Notifier.post("Unknown account", "No Codex account named “\(name ?? "?")”.")
                    continue
                }
                switchCodex(id)
            default:
                break
            }
        }
    }

    // MARK: Status item

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        panel.toggle(from: button)
    }

    /// Two-bar template icon (session over weekly) for the provider picked in
    /// Settings, plus the session percentage unless turned off.
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.toolTip = statusTooltip()
        if state.isSwitching || (codex.isBusy && !codex.pendingNewLogin) {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                   accessibilityDescription: "Switching")
            button.title = ""
            button.toolTip = "Switching accounts…"
            return
        }
        let card = displayedProvider == .claude ? state.cardModel : codex.cardModel
        let session = card.sessionRemaining
        let weekly = card.weeklyRemaining
        button.image = UsageIcon.image(session: session, weekly: weekly,
                                       dimmed: card.isStale || (session == nil && weekly == nil))
        if Preferences.showPercent, let value = session ?? weekly {
            button.attributedTitle = NSAttributedString(
                string: UsageFormat.percent(value),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
        } else {
            button.title = ""
        }
    }

    private func statusTooltip() -> String {
        var lines = ["Agent Profiles"]
        if state.mode == .ready, let active = state.activeProfile {
            if let usage = state.usage[active] {
                lines.append("Claude: \(active)\n\(usage.tooltip)")
            } else {
                lines.append("Claude: \(active) — no usage data yet")
            }
        } else {
            lines.append("Claude: not set up")
        }
        if codex.live?.file != nil {
            var line = "Codex: \(codex.currentTitle)"
            if let remaining = codex.cardModel.sessionRemaining {
                line += " — \(UsageFormat.percent(remaining)) of session left"
            }
            lines.append(line)
        } else {
            lines.append("Codex: not signed in")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Settings window

    /// Opens Settings, optionally on a given pane. The Dock icon shows only
    /// while the window is open; the app is otherwise a menu bar accessory.
    private func showSettings(_ pane: SettingsPane?) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.storageKey) }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(claude: state, codex: codex, updates: updates))
            let window = NSWindow(contentViewController: host)
            window.title = "Agent Profiles Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 760, height: 580))
            window.center()
            window.setFrameAutosaveName("AgentProfilesSettings")
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Closing Settings drops the Dock icon — back to a pure menu bar app.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: Notification clicks

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// The low-limit alerts carry their suggested account in userInfo;
    /// clicking the notification switches straight to it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let target = userInfo["switchTo"] as? String
        let codexTarget = userInfo["switchCodex"] as? String
        let link = (userInfo["openURL"] as? String).flatMap(URL.init(string:))
        Task { @MainActor [weak self] in
            if let target, let self { self.state.switchTo(target) }
            if let codexTarget, let self { self.switchCodex(codexTarget) }
            if let link { NSWorkspace.shared.open(link) }
        }
        completionHandler()
    }

    /// Menu bar apps count as "foreground", which would silently swallow
    /// banners — show them anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
