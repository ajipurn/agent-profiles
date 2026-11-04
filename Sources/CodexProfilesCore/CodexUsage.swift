import Foundation

public struct UsageWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var resetAt: Date?
    public var windowSeconds: Int?

    public init(usedPercent: Double, resetAt: Date? = nil, windowSeconds: Int? = nil) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
    }

    public var remainingPercent: Double {
        usedPercent.isFinite ? min(100, max(0, 100 - usedPercent)) : 0
    }

    public var remainingDisplay: Int {
        let value = remainingPercent
        if value <= 0 { return 0 }
        if value >= 99.5 { return 100 }
        return Int(value.rounded())
    }

    public var label: String {
        Self.label(forWindowSeconds: windowSeconds)
    }

    public var resetsIn: String? {
        guard let resetAt else { return nil }
        return Self.compactDuration(resetAt.timeIntervalSinceNow)
    }

    public var resetCaption: String? {
        guard let resetAt, resetAt > Date() else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(resetAt) || calendar.isDateInTomorrow(resetAt) {
            return resetAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Self.captionLocale))
        }
        return resetAt.formatted(Date.FormatStyle().month(.abbreviated).day().locale(Self.captionLocale))
    }

    private static let captionLocale = Locale(identifier: "en_US")

    public static func label(forWindowSeconds seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "Limit" }
        if abs(seconds - 18_000) <= 1_800 { return "5h" }
        if abs(seconds - 604_800) <= 86_400 { return "Wk" }
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        return "\(max(1, seconds / 60))m"
    }

    public static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }
}

public enum UsageSeverity: Equatable, Sendable {
    case healthy
    case warning
    case critical
    case exhausted
    case unknown
}

public struct CodexUsage: Equatable, Sendable {
    public var planType: String?
    public var allowed: Bool?
    public var limitReached: Bool?
    public var primary: UsageWindow?
    public var secondary: UsageWindow?
    public var creditsBalance: String?
    public var resetCredits: Int?
    /// Extra windows for one feature, such as GPT-5 Codex Spark.
    public var additional: [NamedWindow]
    /// A workspace's per-member credit cap: used and limit, in credits.
    public var creditLimit: CreditLimit?
    public var fetchedAt: Date

    public struct NamedWindow: Equatable, Sendable {
        public var name: String
        public var window: UsageWindow

        public init(name: String, window: UsageWindow) {
            self.name = name
            self.window = window
        }
    }

    public struct CreditLimit: Equatable, Sendable {
        public var used: Double
        public var limit: Double
        public var resetAt: Date?

        public init(used: Double, limit: Double, resetAt: Date? = nil) {
            self.used = used
            self.limit = limit
            self.resetAt = resetAt
        }
    }

    public init(
        planType: String? = nil,
        allowed: Bool? = nil,
        limitReached: Bool? = nil,
        primary: UsageWindow? = nil,
        secondary: UsageWindow? = nil,
        creditsBalance: String? = nil,
        resetCredits: Int? = nil,
        additional: [NamedWindow] = [],
        creditLimit: CreditLimit? = nil,
        fetchedAt: Date = Date()
    ) {
        self.planType = planType
        self.allowed = allowed
        self.limitReached = limitReached
        self.primary = primary
        self.secondary = secondary
        self.creditsBalance = creditsBalance
        self.resetCredits = resetCredits
        self.additional = additional
        self.creditLimit = creditLimit
        self.fetchedAt = fetchedAt
    }

    public var windows: [UsageWindow] {
        [primary, secondary].compactMap { $0 }
    }

    public var severity: UsageSeverity {
        if limitReached == true || allowed == false { return .exhausted }
        let remaining = windows.map(\.remainingPercent)
        guard let worst = remaining.min() else { return .unknown }
        if worst <= 0 { return .exhausted }
        if worst <= 10 { return .critical }
        if worst <= 25 { return .warning }
        return .healthy
    }

    public var compactLine: String {
        if limitReached == true { return "Limit reached" }
        let parts = windows.map { "\($0.remainingDisplay)% \($0.label)" }
        if parts.isEmpty { return "No quota data" }
        return parts.joined(separator: " · ")
    }

    public static func parse(json data: Data, fetchedAt: Date = Date()) throws -> CodexUsage {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any] else {
            throw SwitcherError.invalidAuthFile
        }
        return parse(root: object, fetchedAt: fetchedAt)
    }

    public static func parse(root: [String: Any], fetchedAt: Date = Date()) -> CodexUsage {
        let rateLimit = root["rate_limit"] as? [String: Any]
        let credits = root["credits"] as? [String: Any]
        let resetCredits = root["rate_limit_reset_credits"] as? [String: Any]
        let (primary, secondary) = slots(rateLimit, fetchedAt: fetchedAt)
        return CodexUsage(
            planType: string(root["plan_type"]),
            allowed: rateLimit?["allowed"] as? Bool,
            limitReached: rateLimit?["limit_reached"] as? Bool,
            primary: primary,
            secondary: secondary,
            creditsBalance: (credits?["has_credits"] as? Bool) == false ? nil : creditBalance(credits?["balance"]),
            resetCredits: int(resetCredits?["available_count"]),
            additional: additionalWindows(root["additional_rate_limits"], fetchedAt: fetchedAt),
            creditLimit: creditLimit(root["spend_control"]),
            fetchedAt: fetchedAt
        )
    }

    /// Codex normally sends the 5-hour window as primary and the weekly one
    /// as secondary, but a lone weekly limit can arrive in the primary slot;
    /// it moves to the weekly slot here.
    static func slots(_ rateLimit: [String: Any]?, fetchedAt: Date) -> (UsageWindow?, UsageWindow?) {
        let first = window(rateLimit?["primary_window"], fetchedAt: fetchedAt)
        let second = window(rateLimit?["secondary_window"], fetchedAt: fetchedAt)
        if first?.label == "Wk", second == nil || second?.label == "5h" { return (second, first) }
        return (first, second)
    }

    /// `additional_rate_limits`: one entry per metered feature, each with its
    /// own `rate_limit` windows ("Spark", "Spark weekly").
    static func additionalWindows(_ value: Any?, fetchedAt: Date) -> [NamedWindow] {
        var found: [NamedWindow] = []
        for entry in value as? [Any] ?? [] {
            guard let object = entry as? [String: Any],
                  let rateLimit = object["rate_limit"] as? [String: Any] else { continue }
            let raw = string(object["limit_name"]) ?? string(object["metered_feature"]) ?? "Extra"
            let name = displayName(raw)
            let (short, long) = slots(rateLimit, fetchedAt: fetchedAt)
            if let short { found.append(.init(name: name, window: short)) }
            if let long { found.append(.init(name: "\(name) weekly", window: long)) }
        }
        return found
    }

    /// "gpt-5.3-codex-spark" / "codex_spark" → "Spark"; anything else title-cased.
    static func displayName(_ raw: String) -> String {
        if raw.lowercased().contains("spark") { return "Spark" }
        return raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// `spend_control.individual_limit`; ChatGPT sends the numbers as strings.
    static func creditLimit(_ value: Any?) -> CreditLimit? {
        guard let limit = (value as? [String: Any])?["individual_limit"] as? [String: Any],
              let used = double(limit["used"]), used >= 0,
              let cap = double(limit["limit"]), cap > 0 else { return nil }
        return CreditLimit(used: used, limit: cap,
                           resetAt: double(limit["reset_at"]).map(Date.init(timeIntervalSince1970:)))
    }

    static func window(_ value: Any?, fetchedAt: Date) -> UsageWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let used: Double
        if let remaining = double(object["remaining_percent"]) ?? double(object["percent_remaining"]),
           remaining.isFinite
        {
            used = 100 - remaining
        } else if let usedValue = double(object["used_percent"]), usedValue.isFinite {
            used = usedValue
        } else {
            return nil
        }
        let seconds = int(object["limit_window_seconds"])
        var resetAt: Date?
        if let timestamp = double(object["reset_at"]) {
            resetAt = Date(timeIntervalSince1970: timestamp)
        } else if let after = double(object["reset_after_seconds"]) {
            resetAt = fetchedAt.addingTimeInterval(after)
        }
        return UsageWindow(usedPercent: used, resetAt: resetAt, windowSeconds: seconds)
    }

    static func creditBalance(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "0" ? nil : trimmed
        }
        if let value = value as? NSNumber, value.doubleValue != 0 {
            return value.stringValue
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

public struct UsageLoadState: Equatable, Sendable {
    public var usage: CodexUsage?
    public var error: String?
    public var isLoading: Bool

    public init(usage: CodexUsage? = nil, error: String? = nil, isLoading: Bool = false) {
        self.usage = usage
        self.error = error
        self.isLoading = isLoading
    }

    public static let idle = UsageLoadState()
}
