import Foundation

/// Which usage notifications to send, and at what levels. Kept in
/// UserDefaults under `UsageAlertSettings.*Key`.
public struct UsageAlertSettings: Equatable, Sendable {
    /// Remaining share at or below which a limit warns, and turns critical.
    public var warningLeft: Double
    public var criticalLeft: Double
    public var thresholds: Bool
    /// Pace says the limit runs out before it resets.
    public var willRunOut: Bool
    /// A limit that was used up (or critical) has reset.
    public var resets: Bool
    /// A weekly limit resets within a day with most of it unused.
    public var useItOrLoseIt: Bool

    public init(warningLeft: Double = 25, criticalLeft: Double = 10, thresholds: Bool = true,
                willRunOut: Bool = true, resets: Bool = true, useItOrLoseIt: Bool = false) {
        self.warningLeft = warningLeft
        self.criticalLeft = criticalLeft
        self.thresholds = thresholds
        self.willRunOut = willRunOut
        self.resets = resets
        self.useItOrLoseIt = useItOrLoseIt
    }

    public static let warningKey = "alertWarningLeft"
    public static let criticalKey = "alertCriticalLeft"
    public static let thresholdsKey = "alertThresholds"
    public static let willRunOutKey = "alertWillRunOut"
    public static let resetsKey = "alertResets"
    public static let useItOrLoseItKey = "alertUseItOrLoseIt"

    public static var current: UsageAlertSettings {
        let defaults = UserDefaults.standard
        let base = UsageAlertSettings()
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func level(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: key) as? Double ?? fallback }
        return UsageAlertSettings(
            warningLeft: level(warningKey, base.warningLeft),
            criticalLeft: level(criticalKey, base.criticalLeft),
            thresholds: flag(thresholdsKey, base.thresholds),
            willRunOut: flag(willRunOutKey, base.willRunOut),
            resets: flag(resetsKey, base.resets),
            useItOrLoseIt: flag(useItOrLoseItKey, base.useItOrLoseIt))
    }
}

/// One notification the planner wants sent. `key` identifies the limit's
/// current window, so each alert fires once per window.
public struct UsageAlert: Equatable, Sendable {
    public enum Kind: String, Sendable { case warning, critical, depleted, willRunOut, restored, useItOrLoseIt }

    public var kind: Kind
    public var key: String
    public var limitTitle: String
    public var title: String
    public var body: String
    /// Remaining share when it fired.
    public var remaining: Double
}

/// Decides which usage notifications are due. Pure: the caller remembers
/// what already fired (`fired`) and the last remaining share per limit
/// (`previous`, keyed by `limitKey`).
public enum UsageAlertPlanner {
    public static func limitKey(provider: String, account: String, limit: String) -> String {
        "\(provider)|\(account)|\(limit)"
    }

    /// Reset times drift a little between fetches (Codex reports "resets in
    /// N seconds"), so windows are ten-minute buckets and a window counts as
    /// fired when its own or a neighboring bucket did.
    static func windowIDs(_ limit: UsageLimit) -> (own: String, near: [String]) {
        guard let resetsAt = limit.resetsAt else { return ("open", ["open"]) }
        let bucket = Int((resetsAt.timeIntervalSince1970 / 600).rounded(.down))
        return (String(bucket), [bucket - 1, bucket, bucket + 1].map(String.init))
    }

    public static func alerts(provider: String, account: String, limits: [UsageLimit],
                              settings: UsageAlertSettings, now: Date = Date(),
                              previous: [String: Double], fired: Set<String>) -> [UsageAlert] {
        var due: [UsageAlert] = []
        let who = "\(provider) (\(account))"
        for limit in limits {
            guard let remaining = limit.remaining else { continue }
            let base = limitKey(provider: provider, account: account, limit: limit.title)
            let window = windowIDs(limit)
            func add(_ kind: UsageAlert.Kind, _ title: String, _ body: String) {
                guard !window.near.contains(where: { fired.contains("\(base)|\($0)|\(kind.rawValue)") }) else { return }
                let key = "\(base)|\(window.own)|\(kind.rawValue)"
                due.append(UsageAlert(kind: kind, key: key, limitTitle: limit.title, title: title, body: body,
                                      remaining: remaining))
            }
            let reset = UsageFormat.resetText(limit.resetsAt, now: now).map { $0 + "." } ?? ""
            let name = limit.title.lowercased()

            // Back from empty: the window rolled over since the last look.
            if settings.resets, let before = previous[base], before <= settings.criticalLeft,
               remaining >= max(95, before + 50) {
                add(.restored, "\(who): \(limit.title) reset", "\(UsageFormat.percent(remaining)) of the \(name) limit is available again.")
            }

            // Only the deepest level crossed fires.
            if settings.thresholds {
                if remaining.rounded() <= 0 {
                    add(.depleted, "\(who): \(limit.title) limit used up", reset)
                } else if remaining <= settings.criticalLeft {
                    add(.critical, "\(who) is nearly out — \(UsageFormat.percent(remaining)) of \(name) left", reset)
                } else if remaining <= settings.warningLeft {
                    add(.warning, "\(who): \(UsageFormat.percent(remaining)) of \(name) left", reset)
                }
            }

            // Pace alert, above the critical level (critical covers below it).
            if settings.willRunOut, remaining > settings.criticalLeft {
                let pace = limit.pace(now: now)
                if pace.verdict == .over, let out = pace.runsOutAt, let resetsAt = limit.resetsAt,
                   resetsAt.timeIntervalSince(out) > 15 * 60 {
                    add(.willRunOut, "\(who): \(limit.title) will run out at this pace",
                        "About \(UsageFormat.duration(out.timeIntervalSince(now))) left — "
                        + "\(UsageFormat.duration(resetsAt.timeIntervalSince(out))) before it resets.")
                }
            }

            // A weekly limit about to reset with most of it unused.
            if settings.useItOrLoseIt, (limit.window ?? 0) >= 6 * 86_400, remaining > 50,
               let resetsAt = limit.resetsAt, resetsAt > now, resetsAt.timeIntervalSince(now) <= 86_400 {
                add(.useItOrLoseIt, "\(who): \(UsageFormat.percent(remaining)) of \(name) unused",
                    "It resets in \(UsageFormat.duration(resetsAt.timeIntervalSince(now))).")
            }
        }
        return due
    }
}
