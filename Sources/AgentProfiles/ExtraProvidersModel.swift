import Foundation
import AgentUI
import ProvidersCore

/// Providers beyond Claude and Codex (Gemini, Copilot, …). Each is off until
/// turned on in Settings → More Providers; turned on, it is read every five
/// minutes and whenever the panel opens (at most every two). Read-only:
/// nothing is written to the providers' own files. Antigravity's accounts
/// switch through `AntigravityAccountsModel`.
@MainActor
final class ExtraProvidersModel: ObservableObject {
    static let enabledKey = "enabledProviders"

    struct State: Equatable {
        var snapshot: ProviderSnapshot?
        var error: String?
        var isLoading = false
        var isUnauthorized = false
    }

    let providers: [any UsageProvider]
    @Published private(set) var enabled: [String]
    @Published private(set) var states: [String: State] = [:]
    private var lastFetch: [String: Date] = [:]
    private var timer: Timer?
    private let environment: ProviderEnvironment
    private let demo: Bool

    init(demo: Bool, providers: [any UsageProvider] = ProviderRegistry.all) {
        self.demo = demo
        self.providers = providers
        environment = ProviderEnvironment()
        let known = Set(providers.map(\.id))
        // The preview shares the real app's UserDefaults: it shows a few
        // sample providers and never saves its choices.
        enabled = demo ? Array(providers.prefix(3).map(\.id))
            : (UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? []).filter(known.contains)
        if demo { states = Self.demoStates(providers) }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
        refresh(force: true)
    }

    // MARK: Settings

    func isEnabled(_ id: String) -> Bool { enabled.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        if on, !enabled.contains(id) {
            enabled.append(id)
        } else if !on {
            enabled.removeAll { $0 == id }
            if !demo { states[id] = nil }
        }
        if !demo { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
        if on { fetch(id) }
    }

    func isSignedIn(_ provider: any UsageProvider) -> Bool {
        demo || provider.isSignedIn(in: environment)
    }

    // MARK: Fetching

    /// Enabled providers in Settings order.
    var active: [any UsageProvider] { providers.filter { enabled.contains($0.id) } }

    func refresh(force: Bool = false) {
        for provider in active {
            if !force, let last = lastFetch[provider.id], Date().timeIntervalSince(last) < 120 { continue }
            fetch(provider.id)
        }
    }

    private func fetch(_ id: String) {
        guard !demo, let provider = providers.first(where: { $0.id == id }), states[id]?.isLoading != true else { return }
        lastFetch[id] = Date()
        states[id, default: State()].isLoading = true
        let environment = environment
        Task {
            var state = states[id] ?? State()
            do {
                state.snapshot = try await provider.fetch(in: environment)
                state.error = nil
                state.isUnauthorized = false
            } catch {
                // Keep the last numbers on screen, marked stale.
                state.error = error.localizedDescription
                state.isUnauthorized = (error as? ProviderFetchError) == .unauthorized
            }
            state.isLoading = false
            states[id] = state
        }
    }

    // MARK: Panel

    static func style(_ provider: any UsageProvider) -> ProviderStyle {
        ProviderStyle(id: provider.id, name: provider.name, symbol: provider.symbol, hex: provider.brandHex)
    }

    func cardModel(_ provider: any UsageProvider) -> UsageCardModel {
        var card = UsageCardModel(provider: Self.style(provider))
        card.dashboardURL = provider.dashboardURL
        let state = states[provider.id] ?? State()
        if let snapshot = state.snapshot {
            card.account = snapshot.account
            card.badge = snapshot.plan
            card.subtitle = UsageFormat.updatedText(snapshot.fetchedAt)
            card.limits = Self.limits(snapshot)
            card.details = snapshot.details.map { UsageDetail(title: $0.title, value: $0.value, used: $0.usedPercent) }
            if card.limits.isEmpty, card.details.isEmpty { card.placeholder = "No usage limits reported." }
        } else if state.isLoading || state.error == nil {
            card.placeholder = "Loading usage…"
        }
        if let error = state.error {
            card.notice = error
            card.noticeTone = state.snapshot == nil ? .error : .warning
            card.isStale = state.snapshot != nil
            if state.snapshot == nil { card.placeholder = nil }
        }
        return card
    }

    /// Titles must be unique per group (with it, they key the rows).
    static func limits(_ snapshot: ProviderSnapshot) -> [UsageLimit] {
        var seen: [String: Int] = [:]
        return snapshot.windows.map { window in
            var limit = UsageLimit(title: window.title, remaining: window.remainingPercent, resetsAt: window.resetsAt,
                                   window: window.windowSeconds, group: window.group)
            seen[limit.id, default: 0] += 1
            if seen[limit.id]! > 1 { limit.title += " \(seen[limit.id]!)" }
            return limit
        }
    }

    /// The two windows the menu bar icon (top bar, bottom bar) and switcher show.
    func primaryRemaining(_ id: String) -> (Double?, Double?) {
        let windows = states[id]?.snapshot?.primaryWindows ?? []
        return (windows.first?.remainingPercent, windows.dropFirst().first?.remainingPercent)
    }

    /// The turned-on provider whose desktop app has this bundle ID.
    func activeProvider(forBundleID bundleID: String?) -> (any UsageProvider)? {
        guard let bundleID else { return nil }
        return active.first { $0.appBundleIDs.contains(bundleID) }
    }

    var statusPages: [String: URL] {
        Dictionary(uniqueKeysWithValues: active.compactMap { provider in provider.statusPageURL.map { (provider.id, $0) } })
    }

    // MARK: Preview

    private static func demoStates(_ providers: [any UsageProvider]) -> [String: State] {
        var states: [String: State] = [:]
        let now = Date()
        for (index, provider) in providers.enumerated() {
            let used = [34.0, 72, 18, 55, 91, 8, 46][index % 7]
            states[provider.id] = State(snapshot: ProviderSnapshot(
                account: "demo@example.com", plan: "Pro",
                windows: [ProviderWindow(title: "Monthly", usedPercent: used,
                                         resetsAt: now.addingTimeInterval(Double(index + 3) * 86_400),
                                         windowSeconds: 30 * 86_400),
                          ProviderWindow(title: "Daily", usedPercent: used / 2,
                                         resetsAt: now.addingTimeInterval(6 * 3600), windowSeconds: 86_400)],
                fetchedAt: now))
        }
        return states
    }
}
