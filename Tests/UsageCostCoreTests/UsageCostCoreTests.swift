import Foundation
import Testing
@testable import UsageCostCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func lines(_ rows: [String]) -> Data { Data(rows.joined(separator: "\n").utf8) }

@Suite struct PricingTests {
    @Test func resolvesPrefixesDatesAndTags() {
        let catalog = ["claude-sonnet-4-5": ModelPrice(input: 3, output: 15),
                       "gpt-6.1-sol": ModelPrice(input: 2, output: 10)]
        #expect(Pricing.price(for: "anthropic/claude-sonnet-4-5-20250929", in: catalog)?.standard.input == 3)
        #expect(Pricing.price(for: "claude-sonnet-4.5[1m]", in: catalog)?.standard.input == 3)
        #expect(Pricing.price(for: "gpt-6.1-sol-high", in: catalog)?.standard.input == 2)
        #expect(Pricing.price(for: "mystery-model", in: catalog) == nil)
    }

    @Test func catalogHasCurrentModels() {
        #expect(Pricing.price(for: "claude-opus-5-5") != nil)
        #expect(Pricing.price(for: "gpt-6.1-sol") != nil)
    }

    @Test func pricesEachTokenKind() {
        let price = ModelPrice(input: 1, output: 10, cacheRead: 0.1, cacheWrite: 1.25, cacheWrite1h: 2)
        let usage = TokenUsage(input: 2, output: 3, cacheRead: 10, cacheWrite5m: 4, cacheWrite1h: 5)
        #expect(abs(price.cost(of: usage) - (2 + 30 + 1 + 5 + 10)) < 1e-9)
    }

    @Test func longContextRatesApplyPastThreshold() {
        let price = ModelPrice(standard: Rates(input: 1, output: 1), longContext: Rates(input: 2, output: 3),
                               longContextThreshold: 200_000)
        #expect(price.cost(of: TokenUsage(input: 100, output: 1)) == 101)
        #expect(price.cost(of: TokenUsage(input: 200_001, output: 1)) == 400_005)
        // Codex reports the prompt apart from the billed (uncached) tokens.
        #expect(price.cost(of: TokenUsage(input: 10, output: 1), promptTokens: 300_000) == 23)
    }

    @Test func tiersPickTheirRates() {
        let price = ModelPrice(
            standard: Rates(input: 1, output: 10, cacheRead: 0.1),
            longContext: Rates(input: 2, output: 15, cacheRead: 0.2), longContextThreshold: 1000,
            priority: Rates(input: 4, output: 40, cacheRead: 0.4),
            priorityLongContext: Rates(input: 8, output: 60, cacheRead: 0.8),
            flex: Rates(input: 0.5, output: 5, cacheRead: 0.05))
        let usage = TokenUsage(input: 1, output: 1, cacheRead: 10)
        #expect(price.cost(of: usage, tier: .priority) == 4 + 40 + 4)
        #expect(price.cost(of: usage, tier: .priority, promptTokens: 2000) == 8 + 60 + 8)
        #expect(price.cost(of: usage, tier: .flex) == 0.5 + 5 + 0.5)
        // Without flex long-context rates, a long flex prompt keeps the flex rates.
        #expect(price.cost(of: usage, tier: .flex, promptTokens: 2000) == 0.5 + 5 + 0.5)
    }

    @Test func fastModeScalesEveryTokenKind() {
        let opus = Pricing.price(for: "claude-opus-5-5")!
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // Standard: $4 + $20 + $0.20 + $5 + $8 (platform.claude.com pricing).
        #expect(abs(opus.cost(of: usage) - 37.2) < 1e-9)
        #expect(abs(opus.cost(of: usage, tier: .fast) - 74.4) < 1e-9)
        // Models without fast mode keep their standard price.
        let sonnet = Pricing.price(for: "claude-sonnet-5-5")!
        #expect(sonnet.cost(of: usage, tier: .fast) == sonnet.cost(of: usage))
    }

    /// Official prices (platform.claude.com, 2026-11-07): Haiku 5.5 is $0.10 /
    /// $0.50 / $0.01 cache read / $0.125 5m write / $0.20 1h write, and 5x that
    /// once a prompt (input + cache reads + cache writes) passes 100,000 tokens.
    @Test func catalogPricesHaiku55WithItsLongContextTier() throws {
        let haiku = try #require(Pricing.price(for: "claude-haiku-5-5"))
        #expect(haiku.longContextThreshold == 100_000)
        let mtok = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                              cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // A 5M-token prompt is long: $0.50 + $2.50 + $0.05 + $0.625 + $1.
        #expect(abs(haiku.cost(of: mtok) - 4.675) < 1e-9)
        let short = TokenUsage(input: 40_000, output: 1_000_000, cacheRead: 30_000, cacheWrite5m: 30_000)
        #expect(abs(haiku.cost(of: short) - (0.004 + 0.5 + 0.0003 + 0.00375)) < 1e-9)
        // 100,001 prompt tokens, counting cache reads and writes, crosses the threshold.
        let crossing = TokenUsage(input: 40_001, output: 0, cacheRead: 30_000, cacheWrite5m: 30_000)
        #expect(abs(haiku.cost(of: crossing) - (40_001 * 5e-7 + 30_000 * 5e-8 + 30_000 * 6.25e-7)) < 1e-12)
    }

    /// Cache hits on Sonnet 5.5 cost 0.05x input ($0.10/MTok), not the usual 0.1x.
    @Test func catalogPricesSonnet55CacheReadsAtFivePercent() throws {
        let sonnet = try #require(Pricing.price(for: "claude-sonnet-5-5"))
        #expect(sonnet.standard.cacheRead == 1e-07)
    }

    @Test func catalogCarriesCodexTiersAndLongContext() {
        let sol = Pricing.price(for: "gpt-6.1-sol")!
        #expect(sol.priority != nil && sol.flex != nil)
        #expect(sol.longContextThreshold == 272_000)
    }
}

@Suite struct ParserTests {
    @Test func claudeSplitsCacheWritesAndSkipsNoise() {
        let data = lines([
            #"{"type":"user","timestamp":"2026-10-01T07:00:00.000Z","message":{"role":"user"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T07:06:47.700Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":50,"output_tokens":7,"cache_creation":{"ephemeral_1h_input_tokens":60,"ephemeral_5m_input_tokens":40}}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-01T07:06:48Z","message":{"id":"msg_2","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            "not json",
        ])
        let entries = LogParsers.claude(data, calendar: utc)
        #expect(entries.count == 1)
        #expect(entries[0].tokens == TokenUsage(input: 2, output: 7, cacheRead: 50, cacheWrite5m: 40, cacheWrite1h: 60))
        #expect(entries[0].day.value == 20261001)
        #expect(entries[0].dedupeKey == "claude:msg_1:req_1")
        #expect(entries[0].tier == .standard && entries[0].multiplier == 1 && entries[0].webSearches == 0)
    }

    @Test func claudeReadsFastModeRegionAndSearches() {
        let data = lines([
            #"{"type":"assistant","timestamp":"2026-10-01T07:00:00Z","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":5,"speed":"fast","inference_geo":"us","server_tool_use":{"web_search_requests":3}}}}"#,
        ])
        let entry = LogParsers.claude(data, calendar: utc)[0]
        #expect(entry.tier == .fast)
        #expect(entry.multiplier == 1.1)
        #expect(entry.webSearches == 3)
    }

    @Test func codexCountsGrowthOfTotals() {
        let event = { (time: String, total: (Int, Int, Int), last: (Int, Int, Int)) in
            #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total.0),"cached_input_tokens":\#(total.1),"output_tokens":\#(total.2)},"last_token_usage":{"input_tokens":\#(last.0),"cached_input_tokens":\#(last.1),"output_tokens":\#(last.2)}}}}"#
        }
        let data = lines([
            #"{"timestamp":"2026-10-01T05:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#,
            // Resumed session: totals start high; only the last turn counts.
            event("2026-10-01T05:01:00Z", (1000, 400, 50), (100, 40, 5)),
            event("2026-10-01T05:02:00Z", (1000, 400, 50), (100, 40, 5)), // repeat: no growth
            event("2026-10-01T05:03:00Z", (1300, 600, 80), (300, 200, 30)),
            #"{"timestamp":"2026-10-01T05:04:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
        ])
        let entries = LogParsers.codex(data, calendar: utc)
        #expect(entries.map(\.tokens) == [
            TokenUsage(input: 60, output: 5, cacheRead: 40),
            TokenUsage(input: 100, output: 30, cacheRead: 200),
        ])
        #expect(entries.allSatisfy { $0.model == "gpt-6.1-sol" && $0.provider == .codex })
        #expect(entries.map(\.promptTokens) == [100, 300])
    }

    @Test func codexFollowsTheThreadServiceTier() {
        let count = { (time: String, total: Int) in
            #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"output_tokens":1},"last_token_usage":{"input_tokens":10,"output_tokens":1}}}}"#
        }
        let settings = { (time: String, tier: String) in
            #"{"timestamp":"\#(time)","ordinal":3,"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"\#(tier)"}}}"#
        }
        let data = lines([
            count("2026-10-01T05:00:00Z", 10),
            settings("2026-10-01T05:01:00Z", "priority"),
            count("2026-10-01T05:02:00Z", 20),
            settings("2026-10-01T05:03:00Z", "default"),
            count("2026-10-01T05:04:00Z", 30),
        ])
        #expect(LogParsers.codex(data, calendar: utc).map(\.tier) == [.standard, .priority, .standard])
    }
}

@Suite struct SummaryTests {
    @Test func periodsDedupeAndUnpriced() {
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let day = { (offset: Int) in Day(utc.date(byAdding: .day, value: offset, to: now)!, calendar: utc) }
        let tokens = TokenUsage(input: 1_000_000)
        let entries = [
            UsageEntry(day: day(0), provider: .claude, model: "a", tokens: tokens, dedupeKey: "x"),
            UsageEntry(day: day(0), provider: .claude, model: "a", tokens: tokens, dedupeKey: "x"),
            UsageEntry(day: day(-1), provider: .codex, model: "a", tokens: tokens, dedupeKey: nil),
            UsageEntry(day: day(-29), provider: .codex, model: "a", tokens: tokens, dedupeKey: nil),
            UsageEntry(day: day(-30), provider: .codex, model: "a", tokens: tokens, dedupeKey: nil),
            UsageEntry(day: day(0), provider: .codex, model: "unknown", tokens: tokens, dedupeKey: nil),
        ]
        let summary = CostSummary.summarize(entries, now: now, calendar: utc) { model in
            model == "a" ? ModelPrice(input: 1e-6, output: 0) : nil
        }
        #expect(summary.amount(.today, .claude).dollars == 1)
        #expect(summary.amount(.today, .codex).dollars == 0)
        #expect(summary.amount(.yesterday, .codex).dollars == 1)
        #expect(summary.total(.last30Days).dollars == 3)
        #expect(summary.unpricedModels == ["unknown"])
    }

    @Test func dailyAndModelBreakdown() {
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let day = { (offset: Int) in Day(utc.date(byAdding: .day, value: offset, to: now)!, calendar: utc) }
        let million = TokenUsage(input: 1_000_000)
        let entries = [
            UsageEntry(day: day(0), provider: .claude, model: "big", tokens: million),
            UsageEntry(day: day(0), provider: .claude, model: "big", tokens: million),
            UsageEntry(day: day(0), provider: .codex, model: "small", tokens: million),
            UsageEntry(day: day(-3), provider: .codex, model: "small", tokens: million),
        ]
        let summary = CostSummary.summarize(entries, now: now, calendar: utc) { model in
            ModelPrice(input: model == "big" ? 3e-6 : 1e-6, output: 0)
        }
        #expect(summary.daily[day(0)]?[.claude]?.dollars == 6)
        #expect(summary.daily[day(-3)]?[.codex]?.tokens == 1_000_000)
        #expect(summary.daily[day(-1)] == nil)
        let top = summary.topModels(.last30Days)
        #expect(top.map(\.0.model) == ["big", "small"])
        #expect(top.last?.1.dollars == 2)
        #expect(summary.topModels(on: day(-3)).map(\.0.model) == ["small"])
        #expect(Day.lastDays(30, now: now, calendar: utc).last?.0 == day(0))
        #expect(Day.lastDays(30, now: now, calendar: utc).first?.0 == day(-29))
    }

    @Test func regionMultiplierAndSearchesAddUp() {
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        var entry = UsageEntry(day: Day(now, calendar: utc), provider: .claude, model: "a",
                               tokens: TokenUsage(input: 1_000_000), dedupeKey: nil)
        entry.multiplier = 1.1
        entry.webSearches = 5
        let summary = CostSummary.summarize([entry], now: now, calendar: utc) { _ in ModelPrice(input: 1e-6, output: 0) }
        #expect(abs(summary.amount(.today, .claude).dollars - (1.1 + 0.05)) < 1e-9)
    }
}
