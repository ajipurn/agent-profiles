import Foundation

/// API list prices for one model, USD per token.
public struct ModelPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    /// Prompt-cache writes (Anthropic's 5-minute cache).
    public var cacheWrite: Double?
    /// Anthropic's 1-hour cache writes.
    public var cacheWrite1h: Double?
    // Long-context rates, charged when a request's prompt passes 200k tokens.
    public var inputAbove200k: Double?
    public var outputAbove200k: Double?
    public var cacheReadAbove200k: Double?
    public var cacheWriteAbove200k: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil,
                cacheWrite1h: Double? = nil, inputAbove200k: Double? = nil, outputAbove200k: Double? = nil,
                cacheReadAbove200k: Double? = nil, cacheWriteAbove200k: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.inputAbove200k = inputAbove200k
        self.outputAbove200k = outputAbove200k
        self.cacheReadAbove200k = cacheReadAbove200k
        self.cacheWriteAbove200k = cacheWriteAbove200k
    }

    /// Dollars for one request's tokens.
    public func cost(of usage: TokenUsage) -> Double {
        let prompt = usage.input + usage.cacheWrite5m + usage.cacheWrite1h + usage.cacheRead
        let long = prompt > 200_000
        let input = long ? inputAbove200k ?? self.input : self.input
        let output = long ? outputAbove200k ?? self.output : self.output
        let read = (long ? cacheReadAbove200k : nil) ?? cacheRead ?? input
        let write = (long ? cacheWriteAbove200k : nil) ?? cacheWrite ?? input
        // Anthropic bills 1-hour writes at twice the input rate.
        let write1h = cacheWrite1h ?? (cacheWrite == nil ? input : input * 2)
        return Double(usage.input) * input
            + Double(usage.output) * output
            + Double(usage.cacheRead) * read
            + Double(usage.cacheWrite5m) * write
            + Double(usage.cacheWrite1h) * write1h
    }
}

public enum Pricing {
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
