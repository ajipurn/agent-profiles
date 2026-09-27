import SwiftUI
import AppKit
import Combine
import Observation
import UserNotifications
import ClaudeProfilesCore
import CodexProfilesCore
import CodexProfilesUI

@main
struct AgentProfilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // All real UI is AppKit-owned (status item, popover, main window):
        // MenuBarExtra cannot see right-clicks and its window has no arrow.
        Settings { EmptyView() }
    }
}

// MARK: - App delegate

/// Owns the status item, the arrow popover (left-click), the quick-switch
/// menu (right-click) and the windows for both providers: Claude (Desktop and
/// CLI profiles, from Claude Profiles) and Codex (from Codex Profiles).
/// NSStatusItem + NSPopover instead of MenuBarExtra so both mouse buttons
/// work and the panel gets the native popover chrome.
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
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    private var demoWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    /// Template glyph for when there is no usage to show; tinted by the menu bar.
    private static let menuBarIcon: NSImage? = {
        guard let image = NSImage(named: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        return image
    }()

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
        // One Sparkle controller for the whole app; both panels' update
        // settings drive it.
        updates = UpdateController(enabled: !isDemo) { [weak self] in
            self?.canRelaunchForUpdate ?? false
        }
        codex.updater = updates
        Updater.shared = updates.isAvailable ? Updater(controller: updates) : nil

        state.openWindowHandler = { [weak self] in self?.showMainWindow() }
        // Same bundle guard as Notifier: the notification center throws
        // without a real .app bundle (`swift run`).
        if Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
        HotKeys.install { [weak self] index in
            guard let self, self.state.mode == .ready, !self.state.isSwitching,
                  self.state.claudeAppFound, index < self.state.allProfiles.count else { return }
            let name = self.state.allProfiles[index]
            if name != self.state.activeProfile { self.state.switchTo(name) }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "dev.aji.AgentProfiles.status"
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusImage()

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua) // ClaudeBar-style dark theme
        popover.contentViewController = makePanelHost()

        // The status image is derived state; redraw after every model change
        // (async so the @Published values have actually been written).
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusImage() }
            }
            .store(in: &cancellables)
        observeCodex()
        // Composite images bake in the text color, so menu bar theme flips
        // need a redraw too.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusImage() }
        }

        if isDemo { showDemoWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        codex?.prepareForTermination()
        if let claudeDemoHome { try? FileManager.default.removeItem(at: claudeDemoHome) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, state != nil { showMainWindow() }
        return true
    }

    /// Sparkle may only relaunch while no account operation is in flight.
    private var canRelaunchForUpdate: Bool {
        !state.isSwitching && !codex.isBusy && !codex.pendingNewLogin
    }

    /// The Codex model is @Observable, so there is no objectWillChange to
    /// subscribe to: track what the menu bar shows and re-arm after each change.
    private func observeCodex() {
        withObservationTracking {
            _ = codex.live
            _ = codex.liveUsage
            _ = codex.isBusy
            _ = codex.pendingNewLogin
            _ = codex.currentTitle
            _ = codex.settings.showMenuBarUsage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusImage()
                self?.observeCodex()
            }
        }
    }

    /// Scripting hook (Raycast/Alfred/shell), kept from Claude Profiles:
    /// `claudeprofiles://switch/<name>` switches Desktop,
    /// `claudeprofiles://switch-cli/<name>` the CLI (`Default` = the plain
    /// ~/.claude account), `claudeprofiles://open` shows the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard state != nil else { return }
        for url in urls where url.scheme == "claudeprofiles" {
            let name = url.pathComponents.count > 1 ? url.pathComponents[1] : nil
            switch url.host {
            case "open":
                showMainWindow()
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

    /// One readout in the menu bar: the Claude gauge while Claude profiles are
    /// set up, otherwise the Codex one when its "show in menu bar" setting is
    /// on. The tooltip always covers both.
    private func updateStatusImage() {
        guard let button = statusItem?.button else { return }
        button.toolTip = statusTooltip()
        if state.isSwitching || (codex.isBusy && !codex.pendingNewLogin) {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                   accessibilityDescription: "Switching")
            button.toolTip = "Switching accounts…"
        } else if state.mode == .ready, let active = state.activeProfile {
            if let usage = state.usage[active], let remaining = usage.fiveHourRemaining {
                // The numbers are only as fresh as Claude's own last usage
                // fetch, which can trail the in-app indicator by a while.
                // Once the snapshot is old (and Claude is running, so a
                // refresh is at least possible), the readout goes gray and
                // wears the data's age instead of posing as live.
                let stale = state.claude.isRunning
                    && Date().timeIntervalSince(usage.asOf) > Self.staleAfter
                var suffix: String?
                if stale {
                    suffix = Self.age(since: usage.asOf)
                } else if remaining <= 10, let window = usage.fiveHour, !window.expired,
                          let resetsAt = window.resetsAt, resetsAt > Date() {
                    // In the red zone the readout gains a countdown to the
                    // reset — the number that matters once the window is spent.
                    suffix = Self.countdown(to: resetsAt)
                }
                button.image = MenuBarLevel.composite(remaining: remaining, suffix: suffix, stale: stale)
            } else {
                // Same pill, gray "--": this account has no cached numbers yet
                // (never logged in, or Claude hasn't fetched usage there).
                button.image = MenuBarLevel.composite(remaining: nil)
            }
        } else if codex.settings.showMenuBarUsage, codex.live?.file != nil {
            button.image = MenuBarLevel.composite(remaining: codexFiveHourRemaining)
        } else {
            button.image = Self.menuBarIcon
                ?? NSImage(systemSymbolName: "square.on.square.fill", accessibilityDescription: "Agent Profiles")
        }
    }

    private func statusTooltip() -> String {
        var lines = ["Agent Profiles"]
        if state.mode == .ready, let active = state.activeProfile {
            if let usage = state.usage[active] {
                lines.append("Claude: \(active)\n\(usage.tooltip)")
            } else {
                lines.append("Claude: \(active) — no usage data yet. Open Claude with this profile once.")
            }
        } else {
            lines.append("Claude: not set up")
        }
        if codex.live?.file != nil {
            var line = "Codex: \(codex.currentTitle)"
            if let remaining = codexFiveHourRemaining { line += " — \(remaining)% of 5h left" }
            lines.append(line)
        } else {
            lines.append("Codex: not signed in")
        }
        return lines.joined(separator: "\n")
    }

    /// Remaining share of the live Codex account's 5-hour window; nil while
    /// unknown or when the last fetch failed.
    private var codexFiveHourRemaining: Int? {
        guard codex.liveUsage.error == nil else { return nil }
        return Self.fiveHourRemaining(codex.liveUsage.usage)
    }

    private static func fiveHourRemaining(_ usage: CodexUsage?) -> Int? {
        usage?.windows.first { $0.label == "5h" }?.remainingDisplay
    }

    /// "42m" under an hour, "1h05m" above. Refreshes with each usage poll.
    private static func countdown(to date: Date) -> String {
        let minutes = max(1, Int(date.timeIntervalSinceNow / 60))
        return minutes >= 60
            ? "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m"
            : "\(minutes)m"
    }

    /// Snapshot age beyond which the readout stops posing as live.
    private static let staleAfter: TimeInterval = 30 * 60

    private static func age(since date: Date) -> String {
        let minutes = max(1, Int(-date.timeIntervalSinceNow / 60))
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePanelHost() -> NSViewController {
        let host = NSHostingController(rootView: ProviderPanel(claude: state, codex: codex))
        // The two panels differ in size; the container follows the visible one.
        host.sizingOptions = .preferredContentSize
        return host
    }

    // MARK: Right-click quick menu

    private func showContextMenu() {
        let menu = NSMenu()
        if state.mode == .ready {
            menu.addItem(.sectionHeader(title: "Claude"))
            for (index, name) in state.allProfiles.enumerated() {
                var title = "\(index + 1). \(name)"
                if let remaining = state.usage[name]?.fiveHourRemaining {
                    title += " — \(remaining)%"
                }
                let item = NSMenuItem(title: title,
                                      action: #selector(menuSwitchProfile(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.state = name == state.activeProfile ? .on : .off
                if name == state.activeProfile || state.isSwitching || !state.claudeAppFound {
                    item.action = nil // no action = disabled row, checkmark still shows
                }
                menu.addItem(item)
            }
        }
        let codexProfiles = ProfileList.arranged(
            codex.profiles, query: "", favoritesOnly: false, settings: codex.settings,
            activeID: codex.live?.matchingProfileID, usage: codex.profileUsage)
        if !codexProfiles.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: "Codex"))
            for profile in codexProfiles {
                var title = codex.displayName(for: profile)
                if let remaining = Self.fiveHourRemaining(codex.profileUsage[profile.id]?.usage) {
                    title += " — \(remaining)%"
                }
                let item = NSMenuItem(title: title,
                                      action: #selector(menuSwitchCodexProfile(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                let active = profile.id == codex.live?.matchingProfileID
                item.state = active ? .on : .off
                if active || codex.isBusy || codex.pendingNewLogin {
                    item.action = nil
                }
                menu.addItem(item)
            }
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(menuItem("Manage Claude Profiles…", #selector(menuOpenWindow), key: "o"))
        menu.addItem(menuItem("Refresh Usage", #selector(menuRefreshUsage), key: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Agent Profiles",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        // Momentary menu: attach, click, detach — so the next left-click still
        // opens the popover instead of this menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuSwitchProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        state.switchTo(name)
    }

    @objc private func menuSwitchCodexProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = codex.profiles.first(where: { $0.id == id }) else { return }
        codex.switchTo(profile)
    }

    @objc private func menuOpenWindow() { showMainWindow() }

    @objc private func menuRefreshUsage() {
        state.refreshUsage()
        codex.refreshUsage(force: true)
    }

    // MARK: Windows

    /// The Claude profiles window (list/grid, settings) from Claude Profiles.
    private func showMainWindow() {
        popover.performClose(nil)
        if mainWindow == nil {
            let host = NSHostingController(rootView: WindowView(state: state))
            let window = NSWindow(contentViewController: host)
            window.appearance = NSAppearance(named: .darkAqua) // match the panel's dark theme
            window.title = "Claude — Agent Profiles"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 520, height: 660))
            window.contentMinSize = NSSize(width: 460, height: 440)
            window.center()
            mainWindow = window
        }
        // The app stays a menu bar accessory; the Dock icon exists only while
        // this window is open. SwiftUI's .onDisappear never fires for a
        // kept-alive window that's merely ordered out (isReleasedWhenClosed =
        // false), so the policy flip lives here and in windowWillClose instead.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Closing the window drops the Dock icon — back to a pure menu bar app.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Preview mode also shows the panel as a plain window, so it can be
    /// tried without hunting for the menu bar icon.
    private func showDemoWindow() {
        let window = NSWindow(contentViewController: makePanelHost())
        window.title = "Agent Profiles · Preview"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        demoWindow = window
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
