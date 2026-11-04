import Foundation

public enum CostProvider: String, CaseIterable, Sendable {
    case claude, codex
}

/// Tokens of one request, split the way providers price them. `input`
/// excludes cached tokens.
public struct TokenUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
    public var isEmpty: Bool { total == 0 }
}

/// A local calendar day as yyyymmdd, so days compare and hash cheaply.
public struct Day: Hashable, Comparable, Sendable {
    public let value: Int

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        value = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    public static func < (lhs: Day, rhs: Day) -> Bool { lhs.value < rhs.value }

    /// The last `count` days ending with the one holding `now`, oldest first.
    public static func lastDays(_ count: Int, now: Date = Date(), calendar: Calendar = .current) -> [(Day, Date)] {
        (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: now).map { (Day($0, calendar: calendar), $0) }
        }
    }
}

/// One priced-or-not request read from a log.
public struct UsageEntry: Equatable, Sendable {
    public var day: Day
    public var provider: CostProvider
    public var model: String
    public var tokens: TokenUsage
    /// Identifies a request logged more than once (Claude Code repeats a
    /// message per content block and copies history into resumed sessions).
    public var dedupeKey: String?
    public var tier: PriceTier = .standard
    /// The request's whole prompt, when the log reports it apart from the
    /// billed tokens (Codex); decides long-context rates.
    public var promptTokens: Int?
    /// Scales the whole request (Anthropic's US-only inference is 1.1x).
    public var multiplier: Double = 1
    /// Anthropic server-side web searches, billed per search.
    public var webSearches = 0
}

public enum CostPeriod: String, CaseIterable, Sendable {
    case today, yesterday, last30Days

    public var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last30Days: "30 Days"
        }
    }

    func contains(_ day: Day, today: Day, yesterday: Day, monthStart: Day) -> Bool {
        switch self {
        case .today: day == today
        case .yesterday: day == yesterday
        case .last30Days: day >= monthStart && day <= today
        }
    }
}

public struct CostAmount: Equatable, Sendable {
    public var dollars: Double = 0
    public var tokens: Int = 0

    public init(dollars: Double = 0, tokens: Int = 0) {
        self.dollars = dollars
        self.tokens = tokens
    }

    mutating func add(_ dollars: Double, _ tokens: Int) {
        self.dollars += dollars
        self.tokens += tokens
    }
}

/// Estimated spend per period and provider.
public struct CostSummary: Equatable, Sendable {
    public var amounts: [CostPeriod: [CostProvider: CostAmount]] = [:]
    /// The last 30 days, one entry per day with any priced use.
    public var daily: [Day: [CostProvider: CostAmount]] = [:]
    /// Spend per model and period, for the breakdown.
    public var models: [CostPeriod: [ModelKey: CostAmount]] = [:]
    /// Spend per model and day.
    public var dailyModels: [Day: [ModelKey: CostAmount]] = [:]
    /// Models seen in the logs that no price covers; their tokens are left out.
    public var unpricedModels: Set<String> = []
    public var scannedAt: Date?

    public init() {}

    /// A model as the logs name it, with its provider.
    public struct ModelKey: Hashable, Sendable {
        public var provider: CostProvider
        public var model: String

        public init(provider: CostProvider, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    /// Models by spend, most first.
    public func topModels(_ period: CostPeriod, limit: Int = 5) -> [(ModelKey, CostAmount)] {
        Self.ranked(models[period] ?? [:], limit: limit)
    }

    public func topModels(on day: Day, limit: Int = 5) -> [(ModelKey, CostAmount)] {
        Self.ranked(dailyModels[day] ?? [:], limit: limit)
    }

    private static func ranked(_ map: [ModelKey: CostAmount], limit: Int) -> [(ModelKey, CostAmount)] {
        Array(map.sorted { $0.value.dollars != $1.value.dollars ? $0.value.dollars > $1.value.dollars : $0.key.model < $1.key.model }
            .prefix(limit))
    }

    public func amount(_ period: CostPeriod, _ provider: CostProvider) -> CostAmount {
        amounts[period]?[provider] ?? CostAmount()
    }

    public func total(_ period: CostPeriod) -> CostAmount {
        CostProvider.allCases.reduce(into: CostAmount()) { sum, provider in
            let amount = self.amount(period, provider)
            sum.dollars += amount.dollars
            sum.tokens += amount.tokens
        }
    }

    /// Prices and totals entries, counting each dedupe key once.
    public static func summarize(_ entries: [UsageEntry], now: Date = Date(), calendar: Calendar = .current,
                                 price: (String) -> ModelPrice? = { Pricing.price(for: $0) }) -> CostSummary {
        var summary = CostSummary()
        summary.scannedAt = now
        let today = Day(now, calendar: calendar)
        let yesterday = Day(calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar: calendar)
        let monthStart = Day(calendar.date(byAdding: .day, value: -29, to: now) ?? now, calendar: calendar)
        var seen = Set<String>()
        var prices: [String: ModelPrice?] = [:]
        for entry in entries where entry.day >= monthStart && entry.day <= today {
            if let key = entry.dedupeKey, !seen.insert(key).inserted { continue }
            let modelPrice: ModelPrice?
            if let cached = prices[entry.model] {
                modelPrice = cached
            } else {
                modelPrice = price(entry.model)
                prices[entry.model] = modelPrice
            }
            guard let modelPrice else {
                summary.unpricedModels.insert(entry.model)
                continue
            }
            let dollars = modelPrice.cost(of: entry.tokens, tier: entry.tier, promptTokens: entry.promptTokens)
                * entry.multiplier + Double(entry.webSearches) * Pricing.webSearchCost
            let tokens = entry.tokens.total
            let key = ModelKey(provider: entry.provider, model: entry.model)
            for period in CostPeriod.allCases
            where period.contains(entry.day, today: today, yesterday: yesterday, monthStart: monthStart) {
                summary.amounts[period, default: [:]][entry.provider, default: CostAmount()].add(dollars, tokens)
                summary.models[period, default: [:]][key, default: CostAmount()].add(dollars, tokens)
            }
            summary.daily[entry.day, default: [:]][entry.provider, default: CostAmount()].add(dollars, tokens)
            summary.dailyModels[entry.day, default: [:]][key, default: CostAmount()].add(dollars, tokens)
        }
        return summary
    }
}
