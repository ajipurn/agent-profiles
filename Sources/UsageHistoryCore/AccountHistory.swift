import Foundation

/// The two limits every account has.
public enum UsageWindowKind: String, CaseIterable, Sendable {
    case session, weekly

    public func value(_ sample: UsageSample) -> Double? {
        switch self {
        case .session: sample.session
        case .weekly: sample.weekly
        }
    }
}

/// One account's readings over a stretch of time, oldest first.
public struct AccountHistory: Equatable, Sendable {
    public var account: String
    public var samples: [UsageSample]

    public init(account: String, samples: [UsageSample]) {
        self.account = account
        self.samples = samples
    }

    /// One history per account of `provider`, in `order` (the app's own, so a
    /// color stays with its account); accounts no longer in it come last.
    public static func group(_ samples: [UsageSample], provider: UsageSample.Provider,
                             order: [String]) -> [AccountHistory] {
        var byAccount: [String: [UsageSample]] = [:]
        for sample in samples where sample.provider == provider {
            byAccount[sample.account, default: []].append(sample)
        }
        let known = order.filter { byAccount[$0] != nil }
        let gone = byAccount.keys.filter { !order.contains($0) }.sorted()
        return (known + gone).map { account in
            AccountHistory(account: account, samples: (byAccount[account] ?? []).sorted { $0.at < $1.at })
        }
    }

    public var latest: UsageSample? { samples.last }

    public func peak(_ window: UsageWindowKind) -> Double? {
        samples.compactMap(window.value).max()
    }

    /// What shows as 100% once rounded.
    static let full = 99.5

    /// How often the window filled up: each time it reached 100% from below.
    public func timesFull(_ window: UsageWindowKind) -> Int {
        var count = 0
        var wasFull = false
        for value in samples.compactMap(window.value) {
            let isFull = value >= Self.full
            if isFull && !wasFull { count += 1 }
            wasFull = isFull
        }
        return count
    }

    /// Runs of readings with no gap longer than `gap`, so a chart breaks its
    /// line where nothing was recorded instead of drawing across it.
    public func segments(gap: TimeInterval) -> [[UsageSample]] {
        var runs: [[UsageSample]] = []
        for sample in samples {
            if let last = runs.last?.last, sample.at.timeIntervalSince(last.at) <= gap {
                runs[runs.count - 1].append(sample)
            } else {
                runs.append([sample])
            }
        }
        return runs
    }

    /// At most one reading per `interval`: the highest of `window` within it,
    /// so thinning a month for a chart never hides a full window.
    public func thinned(_ window: UsageWindowKind, every interval: TimeInterval) -> AccountHistory {
        guard interval > 0 else { return self }
        var kept: [UsageSample] = []
        var bucket: Int?
        for sample in samples {
            let current = Int((sample.at.timeIntervalSince1970 / interval).rounded(.down))
            if current != bucket {
                kept.append(sample)
                bucket = current
            } else if let value = window.value(sample), value > (window.value(kept[kept.count - 1]) ?? -1) {
                kept[kept.count - 1] = sample
            }
        }
        return AccountHistory(account: account, samples: kept)
    }

    /// The reading in effect at `date`: the last one at or before it, unless
    /// that is older than `within`.
    public func value(_ window: UsageWindowKind, at date: Date, within: TimeInterval) -> Double? {
        guard let sample = samples.last(where: { $0.at <= date }),
              date.timeIntervalSince(sample.at) <= within
        else { return nil }
        return window.value(sample)
    }
}
