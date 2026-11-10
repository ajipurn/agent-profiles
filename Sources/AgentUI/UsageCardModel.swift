import Foundation

/// One usage limit window as the menu shows it ("Session", "Weekly").
public struct UsageLimit: Equatable, Sendable, Identifiable {
    public var title: String
    /// Remaining share, 0–100. Nil while unknown.
    public var remaining: Double?
    public var resetsAt: Date?
    /// Length of the window, for pacing. Nil when unknown.
    public var window: TimeInterval?
    /// Heading the card shows above this limit ("Gemini Models"); limits in
    /// a row with the same group share one heading.
    public var group: String?

    public var id: String { fullTitle }

    /// The title with its group, for places without the heading
    /// (notifications, tooltips): "Gemini Models · Weekly limit".
    public var fullTitle: String { group.map { "\($0) · \(title)" } ?? title }

    public init(title: String, remaining: Double?, resetsAt: Date? = nil, window: TimeInterval? = nil,
                group: String? = nil) {
        self.title = title
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.window = window
        self.group = group
    }

    public func pace(now: Date = Date()) -> UsagePace {
        UsagePace(remaining: remaining, resetsAt: resetsAt, window: window, now: now)
    }

    /// Verdict from the level alone, for accounts that are not in use, where
    /// a burn-rate projection would describe a past session.
    public var level: UsagePace.Verdict {
        UsagePace(remaining: remaining, resetsAt: nil, window: nil).verdict
    }

    /// The reset worth showing next to a compact meter: still ahead, on a
    /// window that has been used. A window that reads 100% has nothing to
    /// get back, so its countdown would only be noise.
    public func pendingReset(now: Date = Date()) -> Date? {
        guard let resetsAt, resetsAt > now, let remaining, remaining.rounded() < 100 else { return nil }
        return resetsAt
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

/// A value worth a line under the limits: credits, extra usage spend.
public struct UsageDetail: Equatable, Sendable, Identifiable {
    public var title: String
    public var value: String
    /// Used share of a cap, 0–100, when there is one.
    public var used: Double?

    public var id: String { title }

    public init(title: String, value: String, used: Double? = nil) {
        self.title = title
        self.value = value
        self.used = used
    }
}

/// An account other than the active one, offered for switching.
public struct UsageAccount: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The 5-hour and weekly windows as last seen for this account.
    public var session: UsageLimit?
    public var weekly: UsageLimit?
    public var isFavorite: Bool

    public init(id: String, title: String, session: UsageLimit?, weekly: UsageLimit?, isFavorite: Bool = false) {
        self.id = id
        self.title = title
        self.session = session
        self.weekly = weekly
        self.isFavorite = isFavorite
    }

    /// Remaining share of the session window, 0–100.
    public var remaining: Double? { session?.remaining }

    /// The one account with more left than every other (and well clear, over
    /// 40%), worth a "Most left" mark. None when several tie — all at 100%,
    /// say — or only one is listed. Compared as the whole percents the panel
    /// shows, so two accounts that both read "100%" tie.
    public static func leader(in accounts: [UsageAccount]) -> UsageAccount? {
        func shown(_ account: UsageAccount) -> Double? { account.usable?.rounded() }
        guard accounts.count > 1,
              let best = accounts.max(by: { (shown($0) ?? 0) < (shown($1) ?? 0) }),
              let top = shown(best), top > 40 else { return nil }
        let rest = accounts.filter { $0.id != best.id }.compactMap(shown)
        return rest.allSatisfy({ $0 < top }) ? best : nil
    }

    /// Either window has a reset worth showing.
    public func hasPendingReset(now: Date = Date()) -> Bool {
        session?.pendingReset(now: now) != nil || weekly?.pendingReset(now: now) != nil
    }

    /// What this account can actually use now: the tighter of its two
    /// windows, since either one running out blocks it.
    public var usable: Double? {
        switch (session?.remaining, weekly?.remaining) {
        case let (s?, w?): min(s, w)
        case let (s, w): s ?? w
        }
    }
}

/// An outage or degradation posted on the provider's status page.
public struct UsageIncident: Equatable, Sendable {
    public var title: String
    public var url: URL?
    /// Major or critical outage (red), rather than minor (orange).
    public var isMajor: Bool

    public init(title: String, url: URL?, isMajor: Bool) {
        self.title = title
        self.url = url
        self.isMajor = isMajor
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
    /// Lines under the limits (credits, extra usage).
    public var details: [UsageDetail]
    /// Status or problem worth a line of its own (switching, sign-in, errors).
    public var notice: String?
    public var noticeTone: Tone
    /// Shown instead of the limits when there are none.
    public var placeholder: String?
    /// Old numbers: the card and the menu bar icon dim them.
    public var isStale: Bool
    /// Current status-page incident, if any.
    public var incident: UsageIncident?
    /// Where "Usage Dashboard" leads.
    public var dashboardURL: URL?

    public init(
        provider: ProviderStyle,
        account: String? = nil,
        subtitle: String? = nil,
        badge: String? = nil,
        limits: [UsageLimit] = [],
        details: [UsageDetail] = [],
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
        self.details = details
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

/// How the panel shows numbers; Settings → General and clicks on the
/// values themselves change these.
public enum UsageDisplay {
    /// Show (and fill bars with) the used share instead of what is left.
    public static let showsUsedKey = "usageShowsUsed"
    /// Show resets as a clock time ("Resets 3:40 PM") instead of a countdown.
    public static let resetClockKey = "usageResetAsClock"
    /// Mask email addresses in the panel (for screen sharing).
    public static let hidePersonalKey = "hidePersonalInfo"
    /// Sort the panel's accounts by what they have left.
    public static let sortByHeadroomKey = "sortAccountsByHeadroom"

    public static var showsUsed: Bool { UserDefaults.standard.bool(forKey: showsUsedKey) }
    public static var resetAsClock: Bool { UserDefaults.standard.bool(forKey: resetClockKey) }
    public static var hidePersonal: Bool { UserDefaults.standard.bool(forKey: hidePersonalKey) }
    public static var sortByHeadroom: Bool { UserDefaults.standard.object(forKey: sortByHeadroomKey) as? Bool ?? true }
}

public enum UsageFormat {
    /// "Resets in 3h 53m", or nil when no reset is pending.
    public static func resetText(_ date: Date?, now: Date = Date()) -> String? {
        guard let date, date > now else { return nil }
        return "Resets in " + duration(date.timeIntervalSince(now))
    }

    /// "Resets in 3h 53m", or with `clock` "Resets 3:40 PM", "Resets Fri 9:00 AM",
    /// "Resets Nov 12".
    public static func resetText(_ date: Date?, now: Date = Date(), clock: Bool) -> String? {
        guard clock else { return resetText(date, now: now) }
        guard let date, date > now else { return nil }
        return "Resets " + clockText(date, now: now)
    }

    static func clockText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow " + time
        }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// A reset short enough for an account row: "2h 13m", "4d 2h", or with
    /// `clock` "3:40 PM" within a day, "Fri" this week, "Nov 12" later. The
    /// row's tooltip has the full time.
    public static func shortReset(_ date: Date, now: Date = Date(), clock: Bool) -> String {
        let ahead = date.timeIntervalSince(now)
        guard clock else { return duration(ahead) }
        if ahead < 86_400 { return date.formatted(date: .omitted, time: .shortened) }
        if ahead < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "58% left" or, showing used, "42% used".
    public static func share(_ remaining: Double?, showsUsed: Bool) -> String {
        guard let remaining else { return "No data yet" }
        return showsUsed ? "\(percent(100 - remaining)) used" : "\(percent(remaining)) left"
    }

    /// The figure a compact meter shows: remaining, or used.
    public static func compact(_ remaining: Double?, showsUsed: Bool) -> String {
        percent(remaining.map { showsUsed ? 100 - $0 : $0 })
    }

    /// Masks the local part of an email ("j•••@gmail.com") when asked to.
    public static func personal(_ text: String, hide: Bool) -> String {
        guard hide, let at = text.firstIndex(of: "@"), at > text.startIndex else { return text }
        return String(text[text.startIndex]) + "•••" + text[at...]
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

    /// "$12.40" in the given ISO currency.
    public static func money(_ value: Double, currency: String = "USD") -> String {
        value.formatted(.currency(code: currency).locale(Locale(identifier: "en_US")))
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int(value.rounded()))%"
    }
}
