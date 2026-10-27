import Foundation
import CodexProfilesCore
import UsageHistoryCore

extension Commands {
    /// As far back as the app keeps readings.
    static let historyDays = 1...Int(UsageHistory.retention / 86_400)

    /// How each account's limits filled over the last `days`, from the
    /// readings the app keeps for Settings → History. Reads the file only;
    /// it stays the app's to write.
    func history(_ only: Provider?, days: Int) async throws {
        guard only != .claudeCLI else {
            throw CLIError.usage("Claude Code shares its account's usage with Claude Desktop; use history claude")
        }
        let now = Date()
        let samples = await UsageHistory(home: context.home).samples(since: now.addingTimeInterval(-Double(days) * 86_400))
        var objects: [String: Any] = [:]
        var sections: [String] = []
        var anyReadings = false
        for provider in [Provider.claude, .codex] where only == nil || only == provider {
            let reports = historyReports(provider, samples)
            anyReadings = anyReadings || reports.contains { !$0.history.samples.isEmpty }
            objects[provider.jsonKey] = reports.map(\.json)
            sections.append(section(only == nil ? "\(provider.title), last \(days) days" : nil,
                                    HistoryReport.lines(reports, now: now)))
        }
        if json { return emit(only.map { objects[$0.jsonKey]! } ?? objects) }
        if !anyReadings {
            sections.append("No readings yet: the Agent Profiles app keeps one every ten minutes at most while it runs.")
        }
        context.output(sections.joined(separator: "\n"))
    }

    /// Every account in the app's order, with or without readings, then the
    /// ones since removed that still have some.
    func historyReports(_ provider: Provider, _ samples: [UsageSample]) -> [HistoryReport] {
        let kind: UsageSample.Provider
        let known: [(id: String, name: String)]
        switch provider {
        case .codex:
            kind = .codex
            known = ((try? codexProfiles()) ?? []).map { (id: $0.id.uuidString, name: $0.displayName) }
        case .claude, .claudeCLI:
            kind = .claude
            known = claude.ordered(claude.profiles()).map { (id: $0, name: $0) }
        }
        let groups = AccountHistory.group(samples, provider: kind, order: known.map { $0.id })
        let byID = Dictionary(groups.map { ($0.account, $0) }, uniquingKeysWith: { first, _ in first })
        let knownIDs = Set(known.map { $0.id })
        let current = known.map { account -> HistoryReport in
            HistoryReport(provider: provider, id: account.id, name: account.name, removed: false,
                          history: byID[account.id] ?? AccountHistory(account: account.id, samples: []))
        }
        let removed = groups.filter { !knownIDs.contains($0.account) }.map { group -> HistoryReport in
            // A removed Codex account is told apart by the start of its id, as in Settings.
            let name = provider == .codex ? "Removed account \(group.account.prefix(4))" : group.account
            return HistoryReport(provider: provider, id: group.account, name: name, removed: true, history: group)
        }
        return current + removed
    }
}

/// One account's readings over the days asked for.
struct HistoryReport {
    var provider: Provider
    /// The Claude profile's name, or the Codex account's id.
    var id: String
    var name: String
    var removed: Bool
    var history: AccountHistory

    var label: String { removed && provider != .codex ? name + " (removed)" : name }

    var json: [String: Any] {
        var object: [String: Any] = [
            "name": name,
            "removed": removed,
            "lastReading": orNull(history.latest.map { isoDate($0.at) }),
            "session": window(.session),
            "weekly": window(.weekly),
            "readings": history.samples.map {
                ["at": isoDate($0.at), "session": orNull($0.session), "weekly": orNull($0.weekly)] as [String: Any]
            },
        ]
        if provider == .codex { object["id"] = id }
        return object
    }

    func window(_ kind: UsageWindowKind) -> [String: Any] {
        [
            "latest": orNull(history.samples.last(where: { kind.value($0) != nil }).flatMap(kind.value)),
            "peak": orNull(history.peak(kind)),
            "timesFull": history.timesFull(kind),
        ]
    }

    static let columns = ["Weekly peak", "Weekly full", "Session peak", "Session full"]

    /// A table: each column's numbers under its heading, the way Settings
    /// shows them, and how long ago the last reading came.
    static func lines(_ reports: [HistoryReport], now: Date) -> [String] {
        guard !reports.isEmpty else { return [] }
        let width = max("Account".count, reports.map(\.label.count).max() ?? 0) + 2
        func padded(_ text: String) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
        func cell(_ text: String, under heading: String) -> String {
            String(repeating: " ", count: max(0, heading.count - text.count)) + text
        }
        var lines = [padded("Account") + columns.joined(separator: "  ") + "  Last reading"]
        for report in reports {
            guard let last = report.history.latest else {
                lines.append(padded(report.label) + "no readings")
                continue
            }
            let values = [
                percent(report.history.peak(.weekly)), times(report.history.timesFull(.weekly)),
                percent(report.history.peak(.session)), times(report.history.timesFull(.session)),
            ]
            let cells = zip(values, columns).map { cell($0, under: $1) }.joined(separator: "  ")
            let age = UsageWindow.compactDuration(now.timeIntervalSince(last.at))
            lines.append(padded(report.label) + cells + "  " + age + " ago")
        }
        return lines
    }

    static func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "–" }

    static func times(_ count: Int) -> String { count == 0 ? "–" : "\(count)×" }
}
