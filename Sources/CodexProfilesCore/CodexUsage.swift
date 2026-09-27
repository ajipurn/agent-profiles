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
    public var fetchedAt: Date

    public init(
        planType: String? = nil,
        allowed: Bool? = nil,
        limitReached: Bool? = nil,
        primary: UsageWindow? = nil,
        secondary: UsageWindow? = nil,
        creditsBalance: String? = nil,
        resetCredits: Int? = nil,
        fetchedAt: Date = Date()
    ) {
        self.planType = planType
        self.allowed = allowed
        self.limitReached = limitReached
        self.primary = primary
        self.secondary = secondary
        self.creditsBalance = creditsBalance
        self.resetCredits = resetCredits
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
        return CodexUsage(
            planType: string(root["plan_type"]),
            allowed: rateLimit?["allowed"] as? Bool,
            limitReached: rateLimit?["limit_reached"] as? Bool,
            primary: window(rateLimit?["primary_window"], fetchedAt: fetchedAt),
            secondary: window(rateLimit?["secondary_window"], fetchedAt: fetchedAt),
            creditsBalance: creditBalance(credits?["balance"]),
            resetCredits: int(resetCredits?["available_count"]),
            fetchedAt: fetchedAt
        )
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
