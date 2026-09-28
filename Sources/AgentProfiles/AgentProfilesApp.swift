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
/// Codex Profiles). The icon follows the provider picked in Settings.
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
    private var claudeDemoHome: URL?

    private var statusItem: NSStatusItem!
    private var menuController: StatusMenuController!
    private var settingsWindow: NSWindow?
    private var cancellables: [Any] = []
    private var wasCompletingLogin = false

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
        HotKeys.install { [weak self] index in
            guard let self, self.state.canSwitchDesktop, index < self.state.allProfiles.count else { return }
            let name = self.state.allProfiles[index]
            if name != self.state.activeProfile { self.state.switchTo(name) }
        }

        menuController = StatusMenuController(
            claude: state, codex: codex,
            defaultTab: { Preferences.menuBarProvider ?? .claude },
            openSettings: { [weak self] pane in self?.showSettings(pane) })
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "dev.aji.AgentProfiles.status"
        statusItem.menu = menuController.menu
        statusItem.button?.imagePosition = .imageLeading
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
            Task { @MainActor in self?.updateStatusItem() }
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
                self.updateStatusItem()
                self.observeCodex()
            }
        }
    }

    /// Scripting hook (Raycast/Alfred/shell), kept from Claude Profiles:
    /// `claudeprofiles://switch/<name>` switches Desktop,
    /// `claudeprofiles://switch-cli/<name>` the CLI (`Default` = the plain
    /// ~/.claude account), `claudeprofiles://open` shows the Claude settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard state != nil else { return }
        for url in urls where url.scheme == "claudeprofiles" {
            let name = url.pathComponents.count > 1 ? url.pathComponents[1] : nil
            switch url.host {
            case "open":
                showSettings(.claude)
            case "switch":
                guard let name, state.allProfiles.contains(name) else {
                    Notifier.post("Unknown profile", "No profile named “\(name ?? "?")”.")
                    continue
                }
                if name != state.activeProfile { state.switchTo(name) }
            case "switch-cli":
                guard let name else { continue }
                if name == "Default" {
                    state.switchCLI(nil)
                } else if state.allProfiles.contains(name) {
                    state.switchCLI(name)
                } else {
                    Notifier.post("Unknown profile", "No profile named “\(name)”.")
                }
            default:
                break
            }
        }
    }

    // MARK: Status item

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
        let card = (Preferences.menuBarProvider ?? .claude) == .claude ? state.cardModel : codex.cardModel
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
    /// The low-limit alert carries its suggested profile in userInfo;
    /// clicking the notification switches straight to it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let target = userInfo["switchTo"] as? String
        let link = (userInfo["openURL"] as? String).flatMap(URL.init(string:))
        Task { @MainActor [weak self] in
            if let target, let self { self.state.switchTo(target) }
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
