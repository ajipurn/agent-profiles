import Foundation
import AgentUI
import UsageCostCore

/// Estimated spend for the panel's Cost card, rescanned in the background.
@MainActor
final class CostModel: ObservableObject {
    @Published private(set) var summary: CostSummary?
    @Published private(set) var isScanning = false

    private let scanner: CostScanner
    /// Opening the panel repeatedly shouldn't rescan every time.
    private static let minInterval: TimeInterval = 60

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        scanner = CostScanner(sources: .standard(home: home))
    }

    func refresh(force: Bool = false) {
        guard !isScanning else { return }
        if !force, let last = summary?.scannedAt, Date().timeIntervalSince(last) < Self.minInterval { return }
        isScanning = true
        Task {
            let result = await scanner.scan()
            summary = result
            isScanning = false
        }
    }

    var periods: [CostPeriodData] {
        CostPeriod.allCases.map { period in
            CostPeriodData(title: period.title, slices: [
                CostSlice(style: .claude, dollars: summary?.amount(period, .claude).dollars ?? 0,
                          tokens: summary?.amount(period, .claude).tokens ?? 0),
                CostSlice(style: .codex, dollars: summary?.amount(period, .codex).dollars ?? 0,
                          tokens: summary?.amount(period, .codex).tokens ?? 0),
            ])
        }
    }

    var note: String {
        var text = "Estimated at API list prices from local Claude Code and Codex session logs. "
            + "Claude Desktop chats keep no local token log, so they aren't counted; on a subscription "
            + "this is the value of what you used, not a bill."
        if let unpriced = summary?.unpricedModels, !unpriced.isEmpty {
            text += "\n\nNo price yet (left out): " + unpriced.sorted().joined(separator: ", ")
        }
        return text
    }
}
