import Foundation

/// One set of per-token rates (USD).
public struct Rates: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    /// Prompt-cache writes (Anthropic's 5-minute cache).
    public var cacheWrite: Double?
    /// Anthropic's 1-hour cache writes.
    public var cacheWrite1h: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil,
                cacheWrite1h: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
    }

    func cost(of usage: TokenUsage) -> Double {
        let read = cacheRead ?? input
        let write = cacheWrite ?? input
        // Anthropic bills 1-hour writes at twice the input rate.
        let write1h = cacheWrite1h ?? (cacheWrite == nil ? input : input * 2)
        return Double(usage.input) * input
            + Double(usage.output) * output
            + Double(usage.cacheRead) * read
            + Double(usage.cacheWrite5m) * write
            + Double(usage.cacheWrite1h) * write1h
    }
}

/// How a request was served, which changes its price.
public enum PriceTier: Equatable, Sendable {
    case standard
    /// OpenAI's priority processing (Codex "priority"/"fast").
    case priority
    /// OpenAI's flex processing.
    case flex
    /// Anthropic's fast mode.
    case fast
}

/// API list prices for one model.
public struct ModelPrice: Equatable, Sendable {
    public var standard: Rates
    /// Rates once a request's prompt passes `longContextThreshold` tokens.
    public var longContext: Rates?
    public var longContextThreshold: Int?
    public var priority: Rates?
    public var priorityLongContext: Rates?
    public var flex: Rates?
    public var flexLongContext: Rates?
    /// Fast mode scales every token kind by this; nil: not offered.
    public var fastMultiplier: Double?

    public init(standard: Rates, longContext: Rates? = nil, longContextThreshold: Int? = nil,
                priority: Rates? = nil, priorityLongContext: Rates? = nil,
                flex: Rates? = nil, flexLongContext: Rates? = nil, fastMultiplier: Double? = nil) {
        self.standard = standard
        self.longContext = longContext
        self.longContextThreshold = longContextThreshold
        self.priority = priority
        self.priorityLongContext = priorityLongContext
        self.flex = flex
        self.flexLongContext = flexLongContext
        self.fastMultiplier = fastMultiplier
    }

    /// Standard rates only.
    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil,
                cacheWrite1h: Double? = nil) {
        self.init(standard: Rates(input: input, output: output, cacheRead: cacheRead,
                                  cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h))
    }

    /// Dollars for one request's tokens. `promptTokens` is the request's
    /// whole prompt when the log says so (Codex); otherwise it is the sum of
    /// the prompt-side tokens.
    public func cost(of usage: TokenUsage, tier: PriceTier = .standard, promptTokens: Int? = nil) -> Double {
        let prompt = promptTokens ?? (usage.input + usage.cacheRead + usage.cacheWrite5m + usage.cacheWrite1h)
        let long = longContextThreshold.map { prompt > $0 } ?? false
        let longRates = long ? longContext : nil
        let rates: Rates = switch tier {
        case .priority: (long ? priorityLongContext : nil) ?? priority ?? longRates ?? standard
        case .flex: (long ? flexLongContext : nil) ?? flex ?? longRates ?? standard
        case .standard, .fast: longRates ?? standard
        }
        let cost = rates.cost(of: usage)
        return tier == .fast ? cost * (fastMultiplier ?? 1) : cost
    }
}

public enum Pricing {
    /// Anthropic's web search tool: $10 per 1,000 searches.
    public static let webSearchCost = 0.01
    /// Anthropic's US-only inference (`inference_geo: "us"`).
    public static let usInferenceMultiplier = 1.1

    /// The catalog entry for a logged model name, tolerating provider
    /// prefixes, date suffixes and context-size tags.
    public static func price(for model: String, in catalog: [String: ModelPrice] = catalog) -> ModelPrice? {
        for candidate in candidates(model) {
            if let price = catalog[candidate] { return price }
        }
        // A longer, more specific name of a known model ("gpt-6.1-sol-high").
        let base = candidates(model).last ?? model
        return catalog.keys
            .filter { base.hasPrefix($0 + "-") }
            .max { $0.count < $1.count }
            .flatMap { catalog[$0] }
    }

    static func candidates(_ model: String) -> [String] {
        var name = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) } // "[1m]"
        var result = [name]
        // claude-sonnet-4-5-20250929 → claude-sonnet-4-5
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            name.removeSubrange(range)
            result.append(name)
        }
        // claude-haiku-4.5 → claude-haiku-4-5
        let dashed = name.replacingOccurrences(of: ".", with: "-")
        if name.hasPrefix("claude-"), dashed != name { result.append(dashed) }
        return result
    }
}
