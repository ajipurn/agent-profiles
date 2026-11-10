import Foundation
import ClaudeProfilesCore
import CodexProfilesCore

extension UsageSample {
    /// A Claude profile's limits as Claude Desktop last fetched them.
    public static func claude(_ profile: String, _ usage: ProfileUsage) -> UsageSample {
        UsageSample(provider: .claude, account: profile, at: usage.asOf,
                    session: usage.fiveHour.map { clamped($0.percent) },
                    weekly: usage.sevenDay.map { clamped($0.percent) })
    }

    /// A Codex account's limits, told apart by window length as the menu does.
    public static func codex(_ account: UUID, _ usage: CodexUsage) -> UsageSample {
        let session = usage.windows.first { $0.label == "5h" } ?? usage.primary
        let weekly = usage.windows.first { $0.label == "Wk" } ?? usage.secondary.flatMap { $0 == session ? nil : $0 }
        return UsageSample(provider: .codex, account: account.uuidString, at: usage.fetchedAt,
                           session: session.map { clamped($0.usedPercent) },
                           weekly: weekly.map { clamped($0.usedPercent) })
    }

    private static func clamped(_ percent: Double) -> Double { min(100, max(0, percent)) }
}
