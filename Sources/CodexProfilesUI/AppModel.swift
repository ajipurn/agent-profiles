import AppKit
import Darwin
import Foundation
import SwiftUI
import CodexProfilesCore

@MainActor
@Observable
final class AppModel {
    var updater: UpdateController?
    var searchText = ""
    var favoritesOnly = false
    var isRefreshingUsage = false
    var lastUsageCheck: Date?
    var live: LiveState?
    var profiles: [Profile] = []
    var settings: AppSettings = AppSettings()
    var status: String?
    var error: String?
    var isBusy = false
    var draftName = ""
    var editor: EditorMode?
    var awaitingLogin = false
    var pendingNewLogin = false

    private var demoWindow: NSWindow?
    let isDemo: Bool
    private var switcher: AccountSwitcher
    private var usageClient = CodexUsageClient()
    private var loginPollTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var usagePollTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?
    private var previousProfileBeforeLogin: UUID?
    private var lastUsageLoad: Date?
    private var usageRefreshGeneration = 0
    private var usagePollInFlight = false
    private var isUsagePanelOpen = false

    var liveUsage = UsageLoadState()
    var profileUsage: [UUID: UsageLoadState] = [:]

    enum EditorMode: Equatable {
        case save
        case rename(UUID)
        case add
    }

    init(switcher: AccountSwitcher? = nil, demo: Bool = false) {
        isDemo = demo
        if demo {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexProfiles-Demo-" + UUID().uuidString)
            self.switcher = AccountSwitcher(
                paths: CodexPaths(codexHome: root.appendingPathComponent("codex"), storeRoot: root.appendingPathComponent("store")),
                clients: NullCodexClients()
            )
            prepareDemo()
            return
        }
        self.switcher = switcher ?? AccountSwitcher(
            paths: .default(),
            clients: SystemCodexClients()
        )
        refresh()
        refreshUsage(force: true, includeSaved: true, silent: true)
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                if self.settings.autoRefresh && !self.isBusy && !self.pendingNewLogin {
                    self.refresh()
                    if !self.isUsagePanelOpen {
                        self.refreshUsage(force: true, includeSaved: true, silent: true)
                    }
                }
            }
        }
    }

    var visibleProfiles: [Profile] {
        ProfileList.arranged(profiles, query: searchText, favoritesOnly: favoritesOnly,
                             settings: settings, activeID: live?.matchingProfileID, usage: profileUsage)
    }

    func displayName(for profile: Profile) -> String {
        if settings.hideEmails && Profile.looksLikeEmail(profile.displayName) {
            return "Account \((profiles.firstIndex(where: { $0.id == profile.id }) ?? 0) + 1)"
        }
        return profile.displayName
    }

    var menuBarUsage: String? {
        guard settings.showMenuBarUsage, let usage = liveUsage.usage else { return nil }
        guard liveUsage.error == nil else { return "—" }
        guard let fiveHourWindow = usage.windows.first(where: { $0.label == "5h" }) else { return "—" }
        return "\(fiveHourWindow.remainingDisplay)%"
    }

    func toggleFavorite(_ profile: Profile) {
        if settings.favoriteProfileIDs.contains(profile.id) {
            settings.favoriteProfileIDs.remove(profile.id)
        } else {
            settings.favoriteProfileIDs.insert(profile.id)
        }
        updateSettings()
    }

    var currentTitle: String {
        if let active = profiles.first(where: { $0.id == live?.matchingProfileID }) {
            return displayName(for: active)
        }
        if settings.hideEmails, live?.identity != nil { return "Current account" }
        return live?.identity?.title ?? "Not signed in"
    }

    var currentSubtitle: String {
        live?.identity?.subtitle ?? "Add an account to get started"
    }

    var needsSave: Bool {
        live?.file != nil && live?.matchingProfileID == nil
    }

    var isCompletingLogin: Bool {
        editor == .add && pendingNewLogin
    }

    func refresh() {
        let previousFile = live?.file
        do {
            let refreshedLive = try switcher.liveState()
            live = refreshedLive
            profiles = try switcher.profiles()
            settings = switcher.store.loadSettings()
            if settings.restartEditorServer {
                settings.restartEditorServer = false
                try? switcher.store.saveSettings(settings)
            }
            if previousFile != refreshedLive.file {
                lastUsageLoad = nil
                if refreshedLive.file?.isChatGPTSession == true {
                    liveUsage = refreshedLive.matchingProfileID.flatMap { profileUsage[$0] }
                        ?? UsageLoadState(isLoading: true)
                } else {
                    liveUsage = .idle
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func dismissError() {
        error = nil
    }

    func refreshUsage(force: Bool = false, includeSaved: Bool = true, silent: Bool = false) {
        guard !isDemo, !isBusy, !pendingNewLogin else { return }
        if !force, let lastUsageLoad, Date().timeIntervalSince(lastUsageLoad) < 5,
           liveUsage.usage != nil
        {
            return
        }
        if silent, usagePollInFlight { return }
        usageRefreshGeneration += 1
        let generation = usageRefreshGeneration
        if !silent {
            usageTask?.cancel()
            isRefreshingUsage = true
        }
        usagePollInFlight = true
        usageTask = Task {
            defer {
                if generation == self.usageRefreshGeneration {
                    self.usagePollInFlight = false
                    self.isRefreshingUsage = false
                }
            }
            await self.loadUsage(includeSaved: includeSaved, showLoading: !silent)
        }
    }

    func startLiveUsagePolling() {
        guard !isDemo else { return }
        isUsagePanelOpen = true
        usagePollTask?.cancel()
        refreshUsage(force: true, includeSaved: true, silent: liveUsage.usage != nil)
        usagePollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard let self, self.isUsagePanelOpen else { return }
                ticks += 1
                self.refreshUsage(force: true, includeSaved: ticks.isMultiple(of: 8), silent: true)
            }
        }
    }

    func stopLiveUsagePolling() {
        isUsagePanelOpen = false
        usagePollTask?.cancel()
        usagePollTask = nil
    }

    func beginSave() {
        clearFeedback()
        draftName = (try? switcher.suggestedName()) ?? ""
        editor = .save
    }

    func beginRename(_ profile: Profile) {
        clearFeedback()
        draftName = profile.displayName
        editor = .rename(profile.id)
    }

    func beginAdd() {
        guard !isBusy, !pendingNewLogin else { return }
        if isDemo {
            showSuccess("Preview mode uses sample accounts. Open the app normally to sign in.")
            return
        }
        clearFeedback()
        if live?.file != nil, live?.matchingProfileID == nil {
            beginSave()
            error = "Save the current account before adding another one."
            return
        }
        startLogin()
    }

    func cancelEditor() {
        if isCompletingLogin {
            editor = nil
            draftName = ""
            cancelPendingLogin()
            return
        }
        editor = nil
        draftName = ""
        error = nil
    }

    func cancelLogin() {
        guard awaitingLogin else { return }
        awaitingLogin = false
        isBusy = true
        status = "Cancelling login…"
        let task = loginPollTask
        loginPollTask = nil
        task?.cancel()
        Task {
            await task?.value
            await restoreAfterLogin(success: "Login cancelled", failure: nil)
        }
    }

    func commitEditor() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            error = "Enter a name for this account."
            return
        }

        switch editor {
        case .save:
            run("Saving account…") {
                _ = try self.switcher.saveCurrent(name: name)
            } onSuccess: {
                self.editor = nil
                self.draftName = ""
                self.showSuccess("Saved \(name)")
            }
        case .rename(let id):
            run("Renaming account…") {
                _ = try self.switcher.rename(id, to: name)
            } onSuccess: {
                self.editor = nil
                self.draftName = ""
                self.showSuccess("Renamed to \(name)")
            }
        case .add:
            var completionMessage = "Account saved"
            run("Saving account…") {
                let before = Set(try self.switcher.profiles().map(\.id))
                let profile = try await self.switcher.completeNewLogin(name: name)
                completionMessage = before.contains(profile.id)
                    ? "Already saved as \(profile.displayName)"
                    : "Saved \(profile.displayName)"
            } onSuccess: {
                self.editor = nil
                self.draftName = ""
                self.previousProfileBeforeLogin = nil
                self.pendingNewLogin = false
                self.showSuccess(completionMessage)
            }
        case .none:
            break
        }
    }

    func switchTo(_ profile: Profile) {
        guard !pendingNewLogin, profile.id != live?.matchingProfileID else { return }
        let name = displayName(for: profile)
        run("Switching to \(name)…") {
            try await self.switcher.switchTo(profile.id)
        } onSuccess: {
            let suffix = self.settings.restartChatGPT ? "" : " Restart ChatGPT to apply."
            self.showSuccess("Switched to \(name).\(suffix)")
        }
    }

    func delete(_ profile: Profile) {
        guard !pendingNewLogin else { return }
        let name = displayName(for: profile)
        run("Removing \(name)…") {
            try self.switcher.delete(profile.id)
        } onSuccess: {
            self.profileUsage[profile.id] = nil
            self.settings.favoriteProfileIDs.remove(profile.id)
            self.updateSettings()
            self.showSuccess("Removed \(name)")
        }
    }

    func updateSettings() {
        do {
            settings.restartEditorServer = false
            try switcher.store.saveSettings(settings)
        } catch {
            settings = switcher.store.loadSettings()
            status = nil
            self.error = "Unable to save settings. \(error.localizedDescription)"
        }
    }

    func quit() {
        loginPollTask?.cancel()
        usageTask?.cancel()
        usagePollTask?.cancel()
        statusClearTask?.cancel()
        autoRefreshTask?.cancel()
        if isDemo { try? FileManager.default.removeItem(at: switcher.paths.storeRoot.deletingLastPathComponent()) }
        NSApp.terminate(nil)
    }

    private func loadUsage(includeSaved: Bool = true, showLoading: Bool = true) async {
        defer {
            liveUsage.isLoading = false
            for id in profileUsage.keys { profileUsage[id]?.isLoading = false }
        }
        let liveFile = live?.file
        let matchingID = live?.matchingProfileID
        let profiles = self.profiles

        if let liveFile, liveFile.isChatGPTSession {
            if showLoading { liveUsage.isLoading = true }
            do {
                let result = try await usageClient.fetch(snapshot: liveFile)
                guard !Task.isCancelled else { return }
                guard try switcher.liveState().file == liveFile else { return }
                if let updated = result.updatedSnapshot {
                    guard try switcher.applyUsageRefresh(updated, replacing: liveFile, profileID: matchingID) else { return }
                    refresh()
                }
                liveUsage = UsageLoadState(usage: result.usage)
                if let matchingID {
                    profileUsage[matchingID] = liveUsage
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard (try? switcher.liveState().file) == liveFile else { return }
                if !showLoading, liveUsage.usage != nil {
                    return
                }
                liveUsage = UsageLoadState(usage: liveUsage.usage, error: usageMessage(for: error))
                if let matchingID { profileUsage[matchingID] = liveUsage }
            }
        } else {
            liveUsage = .idle
        }

        if includeSaved {
            for profile in profiles where profile.id != matchingID {
                guard !Task.isCancelled else { return }
                if showLoading {
                    var previous = profileUsage[profile.id] ?? .idle
                    previous.isLoading = true
                    profileUsage[profile.id] = previous
                }
                let state = await fetchProfileUsage(profile.id)
                guard !Task.isCancelled else { return }
                profileUsage[state.0] = state.1
            }
        }
        if !Task.isCancelled {
            lastUsageLoad = Date()
            lastUsageCheck = lastUsageLoad
        }
    }

    private func fetchProfileUsage(_ id: UUID) async -> (UUID, UsageLoadState) {
        do {
            let snapshot = try switcher.store.loadSnapshot(id)
            guard snapshot.isChatGPTSession else {
                return (id, .idle)
            }
            let result = try await usageClient.fetch(snapshot: snapshot)
            try Task.checkCancellation()
            guard try switcher.store.loadSnapshot(id) == snapshot else { return (id, profileUsage[id] ?? .idle) }
            if let updated = result.updatedSnapshot {
                guard try switcher.applyUsageRefresh(updated, replacing: snapshot, profileID: id) else {
                    return (id, profileUsage[id] ?? .idle)
                }
            }
            return (id, UsageLoadState(usage: result.usage))
        } catch is CancellationError {
            return (id, profileUsage[id] ?? .idle)
        } catch {
            return (id, UsageLoadState(usage: profileUsage[id]?.usage, error: usageMessage(for: error)))
        }
    }

    private func usageMessage(for error: Error) -> String {
        if let usageError = error as? UsageFetchError, usageError == .unauthorized {
            return "Sign in again to refresh usage."
        }
        return "Unable to load usage. Try again."
    }

    private func startLogin() {
        guard CodexCLI.resolve() != nil else {
            error = "Codex CLI was not found. Install ChatGPT or add codex to this app’s PATH."
            return
        }

        previousProfileBeforeLogin = live?.matchingProfileID
        pendingNewLogin = true
        awaitingLogin = true
        isBusy = true
        status = "Finish signing in in Terminal."
        editor = nil
        loginPollTask?.cancel()
        let pendingUsage = usageTask
        pendingUsage?.cancel()
        loginPollTask = Task { [weak self] in
            guard let self else { return }
            await pendingUsage?.value
            do {
                try Task.checkCancellation()
                try await self.switcher.prepareForNewLogin()
                guard !Task.isCancelled else { return }
                try Self.openLoginTerminal(paths: self.switcher.paths)
                guard !Task.isCancelled else { return }
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                await self.restoreAfterLogin(
                    success: nil,
                    failure: "Unable to start login. \(error.localizedDescription)"
                )
                return
            }

            let deadline = Date().addingTimeInterval(8 * 60)
            while !Task.isCancelled, Date() < deadline {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.refresh()
                if let failure = self.loginFailureMessage() {
                    await self.restoreAfterLogin(success: nil, failure: failure)
                    return
                }
                guard self.switcher.loginDidFinish() else { continue }
                self.loginPollTask = nil
                self.awaitingLogin = false
                self.isBusy = false
                self.status = nil
                self.refresh()
                self.draftName = (try? self.switcher.suggestedName()) ?? "Account"
                self.editor = .add
                return
            }

            if !Task.isCancelled {
                await self.restoreAfterLogin(
                    success: nil,
                    failure: "Login timed out. Try adding the account again."
                )
            }
        }
    }

    private func cancelPendingLogin() {
        isBusy = true
        status = "Restoring previous account…"
        Task {
            await restoreAfterLogin(success: "Login cancelled", failure: nil)
        }
    }

    private func restoreAfterLogin(success: String?, failure: String?) async {
        terminateLoginProcess()
        let previousID = previousProfileBeforeLogin
        do {
            try await switcher.restoreAfterLogin(previousProfileID: previousID)
            refresh()
            if let failure {
                status = nil
                error = failure
            } else if let success {
                showSuccess(success)
            } else {
                status = nil
            }
        } catch {
            status = nil
            self.error = "Unable to restore the previous account. \(error.localizedDescription)"
        }
        previousProfileBeforeLogin = nil
        pendingNewLogin = false
        awaitingLogin = false
        isBusy = false
        refreshUsage(force: true)
    }

    private func loginFailureMessage() -> String? {
        guard let value = try? String(contentsOf: switcher.paths.loginState, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if value == "cancelled" {
            return "Login was cancelled in Terminal."
        }
        if value.hasPrefix("failed:") {
            return "Login failed in Terminal. Try adding the account again."
        }
        return nil
    }

    private func terminateLoginProcess() {
        let paths = switcher.paths
        if let value = try? String(contentsOf: paths.loginProcess, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let rawPID = Int32(value), rawPID > 1
        {
            _ = Darwin.kill(pid_t(rawPID), SIGTERM)
        }
        if let tty = try? String(contentsOf: paths.loginTTY, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !tty.isEmpty
        {
            Self.closeLoginTerminal(tty: tty)
        }
    }

    private func run(
        _ message: String,
        work: @escaping () async throws -> Void,
        onSuccess: @escaping () -> Void = {}
    ) {
        guard !isBusy else { return }
        let pendingUsage = usageTask
        pendingUsage?.cancel()
        statusClearTask?.cancel()
        isBusy = true
        status = message
        error = nil
        Task {
            await pendingUsage?.value
            do {
                try await work()
                self.refresh()
                onSuccess()
            } catch {
                let operationError = error.localizedDescription
                self.refresh()
                self.status = nil
                self.error = operationError
            }
            self.isBusy = false
            self.refreshUsage(force: true)
        }
    }

    private func run(
        _ message: String,
        work: @escaping () throws -> Void,
        onSuccess: @escaping () -> Void = {}
    ) {
        run(message, work: { () async throws in try work() }, onSuccess: onSuccess)
    }

    private func clearFeedback() {
        statusClearTask?.cancel()
        status = nil
        error = nil
    }

    private func showSuccess(_ message: String) {
        statusClearTask?.cancel()
        error = nil
        status = message
        statusClearTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self, self.status == message, !self.isBusy else { return }
            self.status = nil
        }
    }

    func showDemoWindow() {
        guard isDemo, demoWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 690),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Profiles · Preview"
        window.contentViewController = NSHostingController(rootView: MenuPanel().environment(self))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        demoWindow = window
    }

    /// A fully isolated preview: temporary profiles, inert clients, and no network requests.
    private func prepareDemo() {
        do {
            let examples: [(String, String, String, Double, Double)] = [
                ("Personal", "alex@example.com", "pro", 28, 46),
                ("Studio", "alex@studio.example", "team", 62, 81),
                ("Side projects", "dev@example.com", "plus", 8, 17),
                ("Research", "research@example.com", "pro", 100, 34),
                ("Archive", "archive@example.com", "free", 90, 60),
            ]
            for (index, example) in examples.enumerated() {
                let (name, email, plan, hourly, weekly) = example
                let claims: [String: Any] = ["email": email, "name": "Alex Morgan", "sub": "demo-\(index)",
                    "https://api.openai.com/auth": ["chatgpt_plan_type": plan]]
                let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                let data = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
                    "id_token": "demo.\(payload).demo", "access_token": "demo-access", "account_id": "demo-\(index)",
                ]])
                let snapshot = try AuthSnapshot(data: data)
                let profile = try switcher.store.save(name: name, snapshot: snapshot)
                profileUsage[profile.id] = UsageLoadState(usage: CodexUsage(
                    planType: plan, limitReached: hourly == 100,
                    primary: UsageWindow(usedPercent: hourly, resetAt: Date().addingTimeInterval(7_920), windowSeconds: 18_000),
                    secondary: UsageWindow(usedPercent: weekly, resetAt: Date().addingTimeInterval(320_400), windowSeconds: 604_800)
                ))
                if index == 0 { try switcher.writeLiveSnapshot(snapshot) }
                if index == 1 { settings.favoriteProfileIDs.insert(profile.id) }
            }
            try switcher.store.saveSettings(settings)
            refresh()
            lastUsageCheck = Date()
        } catch {
            self.error = "Unable to prepare preview: \(error.localizedDescription)"
        }
    }

    private static func openLoginTerminal(paths: CodexPaths) throws {
        guard let cli = CodexCLI.resolve() else {
            throw SwitcherError.loginFailed("codex CLI not found")
        }
        try SecureFile.ensureDirectory(paths.loginScript.deletingLastPathComponent())
        let body = """
        #!/bin/zsh
        set -uo pipefail
        umask 077
        MARKER=\(zshSingleQuoted(paths.loginMarker.path))
        STATE=\(zshSingleQuoted(paths.loginState.path))
        PIDFILE=\(zshSingleQuoted(paths.loginProcess.path))
        TTYFILE=\(zshSingleQuoted(paths.loginTTY.path))
        CLI=\(zshSingleQuoted(cli.executable.path))
        THIS_TTY="$(tty)"
        LOGIN_PID=""

        cleanup() {
          rm -f "$PIDFILE"
        }
        cancelled() {
          if [[ -n "$LOGIN_PID" ]]; then
            kill "$LOGIN_PID" >/dev/null 2>&1 || true
          fi
          printf 'cancelled\\n' > "$STATE"
          exit 130
        }
        trap cleanup EXIT
        trap cancelled HUP INT TERM

        printf '\\033]0;Codex Profiles Login\\007'
        printf '%s\\n' "$THIS_TTY" > "$TTYFILE"
        printf 'running\\n' > "$STATE"
        rm -f "$MARKER"
        echo "Codex Profiles — sign in to the ChatGPT account you want to add."
        echo

        "$CLI" login &
        LOGIN_PID=$!
        printf '%s\\n' "$LOGIN_PID" > "$PIDFILE"
        wait "$LOGIN_PID"
        STATUS=$?
        if [[ "$STATUS" -ne 0 ]]; then
          printf 'failed:%s\\n' "$STATUS" > "$STATE"
          exit "$STATUS"
        fi

        touch "$MARKER"
        printf 'succeeded\\n' > "$STATE"
        (
          sleep 0.4
          /usr/bin/osascript - "$THIS_TTY" <<'APPLESCRIPT'
        on run argv
          set ttyName to item 1 of argv
          tell application "Terminal"
            repeat with w in windows
              try
                if (tty of selected tab of w) is ttyName then
                  close w saving no
                end if
              end try
            end repeat
          end tell
        end run
        APPLESCRIPT
        ) >/dev/null 2>&1 &
        disown
        exit 0
        """
        try body.write(to: paths.loginScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: paths.loginScript.path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", paths.loginScript.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw SwitcherError.loginFailed("could not open Terminal")
        }
    }

    private static func closeLoginTerminal(tty: String) {
        let source = """
        on run argv
          set ttyName to item 1 of argv
          tell application "Terminal"
            repeat with w in windows
              try
                if (tty of selected tab of w) is ttyName then
                  close w saving no
                end if
              end try
            end repeat
          end tell
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-", tty]
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(source.utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
        }
    }

    private static func zshSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
