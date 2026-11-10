import AppKit
import Darwin
import Foundation
import AgentUI
import ProvidersCore

/// Antigravity's Google accounts, switched like Codex's: the panel lists
/// the saved accounts that aren't signed in, with their usage, and Add
/// Account opens Antigravity signed out so another account can sign in.
/// Saving starts with Add Account; from then on, an account that signs in
/// to Antigravity some other way is saved too.
@MainActor
final class AntigravityAccountsModel: ObservableObject {
    @Published private(set) var accounts: [AntigravityAccount] = []
    @Published private(set) var liveEmail: String?
    @Published private(set) var usage: [UUID: ProviderSnapshot] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var awaitingSignIn = false

    static let providerID = "antigravity"

    /// Antigravity's sign-in changed (switched, added): its card reloads.
    var signInChanged: () -> Void = {}
    /// Whether Antigravity is on in More Providers; nothing is read while it is off.
    var isActive: () -> Bool = { false }

    private let store: AntigravityAccounts
    private let app: any AntigravityAppControl
    private let environment = ProviderEnvironment()
    private let demo: Bool
    private var previousAccount: UUID?
    private var signInWatch: Task<Void, Never>?
    private var lastUsageFetch = Date.distantPast
    private var fetching: Set<UUID> = []
    /// Bumped by each reload; an older one finishing late is dropped.
    private var generation = 0
    private var timer: Timer?

    /// How long Add Account waits for a sign-in before putting the previous account back.
    static let signInTimeout: TimeInterval = 15 * 60

    init(demo: Bool, store: AntigravityAccounts = .standard(), app: any AntigravityAppControl = AntigravityApp()) {
        self.demo = demo
        self.store = store
        self.app = app
        if demo {
            loadDemo()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive() else { return }
                self.refresh(force: true)
            }
        }
    }

    // MARK: State

    /// The saved account Antigravity is signed in with.
    var liveAccount: AntigravityAccount? {
        guard let liveEmail else { return nil }
        return accounts.first { $0.matches(liveEmail) }
    }

    var canSwitch: Bool { !isBusy && !awaitingSignIn }

    /// Saved accounts other than the signed-in one, for Switch Account.
    var menuAccounts: [UsageAccount] {
        accounts.filter { $0.id != liveAccount?.id }.map { account in
            let windows = usage[account.id]?.primaryWindows ?? []
            func limit(_ seconds: TimeInterval) -> UsageLimit? {
                windows.first { $0.windowSeconds == seconds }.map { window in
                    UsageLimit(title: window.title, remaining: window.remainingPercent,
                               resetsAt: window.resetsAt, window: window.windowSeconds)
                }
            }
            return UsageAccount(id: account.id.uuidString, title: account.email,
                                session: limit(5 * 3600), weekly: limit(7 * 86_400))
        }
    }

    func accountID(matching name: String) -> String? {
        accounts.first { $0.matches(name) || $0.id.uuidString == name }?.id.uuidString
    }

    func email(of id: String) -> String? {
        accounts.first { $0.id.uuidString == id }?.email
    }

    // MARK: Loading

    /// Re-reads the saved accounts and Antigravity's sign-in, then the
    /// others' usage when it is older than two minutes (or `force`).
    func refresh(force: Bool = false) {
        guard !demo, isActive() else { return }
        Task {
            await reload()
            refreshUsage(force: force)
        }
    }

    func reload() async {
        guard !demo else { return }
        generation += 1
        let current = generation
        let store = store
        let capture = !accounts.isEmpty || !store.list().isEmpty
        let (accounts, email) = await Task.detached { () async -> ([AntigravityAccount], String?) in
            let email = await store.liveEmail()
            // Once accounts are being saved, keep any that signs in.
            if capture, let email, !store.list().contains(where: { $0.matches(email) }) {
                _ = try? await store.saveLive()
            }
            return (store.list(), email)
        }.value
        guard current == generation else { return }
        self.accounts = accounts
        liveEmail = email
        let known = Set(accounts.map(\.id))
        usage = usage.filter { known.contains($0.key) }
        errors = errors.filter { known.contains($0.key) }
    }

    private func refreshUsage(force: Bool) {
        guard !demo, force || Date().timeIntervalSince(lastUsageFetch) > 120 else { return }
        lastUsageFetch = Date()
        let store = store, environment = environment
        for account in accounts where account.id != liveAccount?.id && !fetching.contains(account.id) {
            let id = account.id
            fetching.insert(id)
            Task {
                let result = await Task.detached { () -> Result<ProviderSnapshot, any Error> in
                    guard let signIn = store.signIn(id) else { return .failure(AntigravityAccountError.unknownAccount) }
                    do {
                        return .success(try await AntigravityProvider(savedSignIn: signIn).fetch(in: environment))
                    } catch {
                        return .failure(error)
                    }
                }.value
                fetching.remove(id)
                switch result {
                case .success(let snapshot):
                    usage[id] = snapshot
                    errors[id] = nil
                case .failure(let error):
                    errors[id] = error.localizedDescription
                }
            }
        }
    }

    // MARK: Actions

    func switchTo(_ id: String) {
        guard canSwitch, let uuid = UUID(uuidString: id), uuid != liveAccount?.id,
              let account = accounts.first(where: { $0.id == uuid }) else { return }
        if demo {
            liveEmail = account.email
            return
        }
        isBusy = true
        let store = store, app = app
        Task {
            do {
                try await store.switchTo(uuid, app: app)
                Notifier.post("Antigravity: switched to \(account.email)")
            } catch {
                Notifier.post("Antigravity switch failed", error.localizedDescription)
            }
            isBusy = false
            await reload()
            signInChanged()
            refreshUsage(force: true)
        }
    }

    /// Opens Antigravity signed out; the account that signs in is saved.
    func add() {
        guard canSwitch, !demo else { return }
        isBusy = true
        let store = store, app = app
        Task {
            do {
                previousAccount = try await store.beginAdding(app: app)?.id
                awaitingSignIn = true
                watchForSignIn()
            } catch {
                Notifier.post("Antigravity: couldn't add an account", error.localizedDescription)
            }
            isBusy = false
            await reload()
            signInChanged()
        }
    }

    /// Stops waiting; signs the previous account in again if nobody signed in.
    func cancelAdd() {
        guard awaitingSignIn else { return }
        signInWatch?.cancel()
        awaitingSignIn = false
        isBusy = true
        let previous = previousAccount
        previousAccount = nil
        let store = store, app = app
        Task {
            do {
                try await store.cancelAdding(restoring: previous, app: app)
            } catch {
                Notifier.post("Antigravity: couldn't sign the previous account in again", error.localizedDescription)
            }
            isBusy = false
            await reload()
            signInChanged()
        }
    }

    /// Forgets a saved account (not the one signed in).
    func remove(_ id: UUID) {
        guard canSwitch, id != liveAccount?.id else { return }
        if demo {
            accounts.removeAll { $0.id == id }
            return
        }
        do {
            try store.remove(id)
        } catch {
            Notifier.post("Antigravity: couldn't remove the account", error.localizedDescription)
        }
        Task { await reload() }
    }

    private func watchForSignIn() {
        signInWatch?.cancel()
        let store = store
        let deadline = Date().addingTimeInterval(Self.signInTimeout)
        signInWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.awaitingSignIn else { return }
                if let account = await Task.detached(operation: { await store.finishAdding() }).value {
                    self.awaitingSignIn = false
                    self.previousAccount = nil
                    Notifier.post("Antigravity: \(account.email) saved",
                                  "Switch between your Antigravity accounts from the Agent Profiles panel.")
                    await self.reload()
                    self.signInChanged()
                    self.refreshUsage(force: true)
                    return
                }
                if Date() > deadline {
                    self.cancelAdd()
                    return
                }
            }
        }
    }

    // MARK: Preview

    private func loadDemo() {
        let now = Date()
        accounts = [AntigravityAccount(email: "demo@example.com"), AntigravityAccount(email: "work@example.com"),
                    AntigravityAccount(email: "side@example.com")]
        liveEmail = accounts[0].email
        for (index, account) in accounts.enumerated().dropFirst() {
            let used = [0, 22.0, 64][index]
            usage[account.id] = ProviderSnapshot(
                account: account.email, plan: "Pro",
                windows: [ProviderWindow(title: "5h limit", usedPercent: used, resetsAt: now.addingTimeInterval(9000),
                                         windowSeconds: 5 * 3600),
                          ProviderWindow(title: "Weekly limit", usedPercent: used / 2,
                                         resetsAt: now.addingTimeInterval(4 * 86_400), windowSeconds: 7 * 86_400)],
                fetchedAt: now)
        }
    }
}

/// The Antigravity app, by bundle ID; its language server lives inside it.
struct AntigravityApp: AntigravityAppControl {
    static let bundleID = "com.google.antigravity"

    func isInstalled() async -> Bool {
        await MainActor.run { Self.appURL != nil }
    }

    func isRunning() async -> Bool {
        await MainActor.run { !Self.running().isEmpty }
    }

    func quit() async -> Bool {
        let apps = await MainActor.run { () -> [NSRunningApplication] in
            let apps = Self.running()
            apps.forEach { $0.terminate() }
            return apps
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await Self.ended(apps) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await MainActor.run { apps.filter { !$0.isTerminated }.forEach { $0.forceTerminate() } }
        Self.bundleProcesses().forEach { kill($0, SIGTERM) }
        try? await Task.sleep(for: .seconds(1))
        return await Self.ended(apps)
    }

    func launch(activate: Bool) async {
        guard let url = await MainActor.run(body: { Self.appURL }) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    @MainActor private static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    @MainActor private static func running() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    private static func ended(_ apps: [NSRunningApplication]) async -> Bool {
        await MainActor.run { apps.allSatisfy(\.isTerminated) } && bundleProcesses().isEmpty
    }

    /// Processes run from inside the app bundle: its helpers and the
    /// language server, which writes the sign-in and may outlive the window.
    private static func bundleProcesses() -> [pid_t] {
        let bundles = ["/Applications/Antigravity.app",
                       FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/Antigravity.app"]
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(min(count, pids.count)).filter { pid in
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            let executable = String(cString: path)
            return bundles.contains { executable.hasPrefix($0 + "/") }
        }
    }
}
