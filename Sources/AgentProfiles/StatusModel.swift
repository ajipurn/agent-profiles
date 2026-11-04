import Foundation
import AgentUI
import ProvidersCore

/// Open incidents on each provider's status page, checked every five
/// minutes (public Statuspage JSON, no credentials). Off when Settings says so.
@MainActor
final class StatusModel: ObservableObject {
    static let enabledKey = "checkStatusPages"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    @Published private(set) var incidents: [String: StatusIncident] = [:]
    private var pages: [String: URL] = [:]
    private var lastCheck = Date.distantPast
    private var timer: Timer?
    private let session = ProviderEnvironment.makeSession()
    private let demo: Bool

    init(demo: Bool) {
        self.demo = demo
    }

    /// Provider id → Statuspage base URL. Claude and Codex always; extras as enabled.
    func watch(_ pages: [String: URL]) {
        guard pages != self.pages else { return }
        self.pages = pages
        incidents = incidents.filter { pages[$0.key] != nil }
        refresh(force: true)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh(force: true) }
            }
        }
    }

    func refresh(force: Bool = false) {
        guard !demo, Self.isEnabled else {
            if !incidents.isEmpty { incidents = [:] }
            return
        }
        guard force || Date().timeIntervalSince(lastCheck) > 120 else { return }
        lastCheck = Date()
        let pages = pages
        let session = session
        Task {
            var found: [String: StatusIncident] = [:]
            await withTaskGroup(of: (String, StatusIncident?).self) { group in
                for (id, url) in pages {
                    group.addTask { (id, try? await StatusPage.fetch(url, session: session)) }
                }
                for await (id, incident) in group { if let incident { found[id] = incident } }
            }
            if found != incidents { incidents = found }
        }
    }

    func incident(for id: String) -> UsageIncident? {
        incidents[id].map { UsageIncident(title: $0.title, url: $0.pageURL, isMajor: $0.isMajor) }
    }

    static let claudePage = URL(string: "https://status.claude.com")!
    static let codexPage = URL(string: "https://status.openai.com")!
}
