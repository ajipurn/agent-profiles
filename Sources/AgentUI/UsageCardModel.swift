import Foundation

/// One usage limit window as the menu shows it ("Session", "Weekly").
public struct UsageLimit: Equatable, Sendable, Identifiable {
    public var title: String
    /// Remaining share, 0–100. Nil while unknown.
    public var remaining: Double?
    public var resetsAt: Date?
    /// Length of the window, for pacing. Nil when unknown.
    public var window: TimeInterval?

    public var id: String { title }

    public init(title: String, remaining: Double?, resetsAt: Date? = nil, window: TimeInterval? = nil) {
        self.title = title
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.window = window
    }

    public func pace(now: Date = Date()) -> UsagePace {
        UsagePace(remaining: remaining, resetsAt: resetsAt, window: window, now: now)
    }
}

/// Where the current burn rate lands by the reset (as OpenUsage does it):
/// on course with room to spare, cutting it close, or running out first.
public struct UsagePace: Equatable, Sendable {
    public enum Verdict: Sendable { case comfortable, tight, over }

    public var verdict: Verdict
    /// Projected share left at the reset (negative: over the limit).
    public var projectedLeft: Double?
    /// Remaining share an even burn would leave right now, 0–100.
    public var evenRemaining: Double?
    /// When the limit runs out at this rate, if before the reset.
    public var runsOutAt: Date?

    /// Windows younger than this have too little history to project.
    static let minElapsedShare = 0.05

    public init(remaining: Double?, resetsAt: Date?, window: TimeInterval?, now: Date = Date()) {
        projectedLeft = nil
        evenRemaining = nil
        runsOutAt = nil
        guard let remaining else { verdict = .comfortable; return }
        let used = 100 - remaining
        if let resetsAt, let window, window > 0, resetsAt > now {
            let left = min(resetsAt.timeIntervalSince(now), window)
            let elapsedShare = 1 - left / window
            evenRemaining = 100 * (1 - elapsedShare)
            if elapsedShare >= Self.minElapsedShare, used > 0 {
                let projected = used / elapsedShare
                projectedLeft = 100 - projected
                if projected > 100 {
                    let rate = used / (window - left) // % per second
                    runsOutAt = now.addingTimeInterval(remaining / rate)
                }
            }
        }
        if remaining.rounded() <= 0 {
            verdict = .over
        } else if let projectedLeft {
            verdict = projectedLeft >= 10 ? .comfortable : projectedLeft > 0.5 ? .tight : .over
        } else {
            verdict = remaining <= 10 ? .over : remaining <= 20 ? .tight : .comfortable
        }
    }
}

/// An account other than the active one, offered for switching.
public struct UsageAccount: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Remaining share of the session window, 0–100.
    public var remaining: Double?
    public var isFavorite: Bool

    public init(id: String, title: String, remaining: Double?, isFavorite: Bool = false) {
        self.id = id
        self.title = title
        self.remaining = remaining
        self.isFavorite = isFavorite
    }
}

/// Everything the menu card shows for one provider.
public struct UsageCardModel: Equatable, Sendable {
    public enum Tone: Sendable { case info, warning, error }

    public var provider: ProviderStyle
    /// Active account, shown on the right of the title.
    public var account: String?
    /// Freshness line under the title ("Updated 2m ago").
    public var subtitle: String?
    /// Plan or context, right of the subtitle.
    public var badge: String?
    public var limits: [UsageLimit]
    /// Status or problem worth a line of its own (switching, sign-in, errors).
    public var notice: String?
    public var noticeTone: Tone
    /// Shown instead of the limits when there are none.
    public var placeholder: String?
    /// Old numbers: the card and the menu bar icon dim them.
    public var isStale: Bool

    public init(
        provider: ProviderStyle,
        account: String? = nil,
        subtitle: String? = nil,
        badge: String? = nil,
        limits: [UsageLimit] = [],
        notice: String? = nil,
        noticeTone: Tone = .info,
        placeholder: String? = nil,
        isStale: Bool = false
    ) {
        self.provider = provider
        self.account = account
        self.subtitle = subtitle
        self.badge = badge
        self.limits = limits
        self.notice = notice
        self.noticeTone = noticeTone
        self.placeholder = placeholder
        self.isStale = isStale
    }

    /// Remaining shares of the "Session" and "Weekly" windows, for the
    /// switcher and the menu bar icon.
    public var sessionRemaining: Double? { limits.first { $0.title == "Session" }?.remaining }
    public var weeklyRemaining: Double? { limits.first { $0.title == "Weekly" }?.remaining }
}

public enum UsageFormat {
    /// "Resets in 3h 53m", or nil when no reset is pending.
    public static func resetText(_ date: Date?, now: Date = Date()) -> String? {
        guard let date, date > now else { return nil }
        return "Resets in " + duration(date.timeIntervalSince(now))
    }

    /// "Updated just now" / "Updated 5m ago" / "Updated 3d ago".
    public static func updatedText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not updated yet" }
        let seconds = now.timeIntervalSince(date)
        return seconds < 60 ? "Updated just now" : "Updated \(duration(seconds)) ago"
    }

    /// "42m", "3h 53m", "3d 20h", "<1m".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// "Limit in 3h 5m" / "Limit reached".
    public static func limitText(_ date: Date?, now: Date = Date()) -> String {
        guard let date, date > now else { return "Limit reached" }
        return "Limit in " + duration(date.timeIntervalSince(now))
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int(value.rounded()))%"
    }
}
