import Foundation
import ClaudeProfilesCore
import CodexProfilesCore
import UsageHistoryCore

/// Preview data: two weeks of made-up readings for the sample accounts, so
/// Settings → History has something to show in `--demo`.
enum HistoryDemo {
    static func samples(claude: [String], codex: [UUID], now: Date = Date()) -> [UsageSample] {
        var random = SplitMix(seed: 7)
        let accounts = claude.map { (UsageSample.Provider.claude, $0) } + codex.map { (UsageSample.Provider.codex, $0.uuidString) }
        var samples: [UsageSample] = []
        for (index, (provider, account)) in accounts.enumerated() {
            let pace = 0.6 + Double(index % 3) * 0.35 // how hard this account gets used
            var session = 0.0, weekly = 0.0
            var time = now.addingTimeInterval(-14 * 86_400)
            var sessionStart = time
            var weekStart = time
            while time <= now {
                defer { time = time.addingTimeInterval(30 * 60) }
                if time.timeIntervalSince(weekStart) >= 7 * 86_400 { weekly = 0; weekStart = time }
                if time.timeIntervalSince(sessionStart) >= 5 * 3600 { session = 0; sessionStart = time }
                let hour = Calendar.current.component(.hour, from: time)
                if (1..<7).contains(hour) { continue } // the Mac asleep: a gap in the lines
                if (9..<19).contains(hour) {
                    let burst = Double.random(in: 0...2, using: &random) * pace
                    session = min(100, session + burst * 9)
                    weekly = min(100, weekly + burst * 0.55)
                }
                samples.append(UsageSample(provider: provider, account: account, at: time, session: session, weekly: weekly))
            }
        }
        return samples
    }

    /// Same numbers on every launch, so screenshots stay comparable.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
