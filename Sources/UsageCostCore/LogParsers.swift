import Foundation
import PlatformSupport

/// Reads token usage out of Claude Code and Codex session logs (JSON lines).
/// Lines that can't carry usage are skipped before any JSON decoding, which
/// keeps multi-megabyte sessions cheap.
public enum LogParsers {
    // MARK: Claude Code

    private struct ClaudeLine: Decodable {
        struct Message: Decodable {
            var id: String?
            var model: String?
            var usage: Usage?
        }
        struct Usage: Decodable {
            struct CacheCreation: Decodable {
                var ephemeral_5m_input_tokens: Int?
                var ephemeral_1h_input_tokens: Int?
            }
            struct ServerTools: Decodable {
                var web_search_requests: Int?
            }
            var input_tokens: Int?
            var output_tokens: Int?
            var cache_creation_input_tokens: Int?
            var cache_read_input_tokens: Int?
            var cache_creation: CacheCreation?
            var server_tool_use: ServerTools?
            var speed: String?
            var inference_geo: String?
        }
        var timestamp: String?
        var requestId: String?
        var message: Message?
    }

    /// Assistant messages with usage from one `~/.claude/projects/**.jsonl`.
    public static func claude(_ data: Data, calendar: Calendar = .current) -> [UsageEntry] {
        let decoder = JSONDecoder()
        var entries: [UsageEntry] = []
        forEachLine(in: data, containing: [#""usage""#, #""assistant""#]) { line in
            guard let parsed = try? decoder.decode(ClaudeLine.self, from: line),
                  let message = parsed.message, let usage = message.usage,
                  let model = message.model, model != "<synthetic>",
                  let date = parsed.timestamp.flatMap(Timestamps.parse) else { return }
            let writes = usage.cache_creation_input_tokens ?? 0
            let oneHour = min(writes, usage.cache_creation?.ephemeral_1h_input_tokens ?? 0)
            let tokens = TokenUsage(
                input: usage.input_tokens ?? 0,
                output: usage.output_tokens ?? 0,
                cacheRead: usage.cache_read_input_tokens ?? 0,
                cacheWrite5m: writes - oneHour,
                cacheWrite1h: oneHour)
            guard !tokens.isEmpty else { return }
            let key = message.id.map { id in "claude:\(id):\(parsed.requestId ?? "")" }
            entries.append(UsageEntry(
                day: Day(date, calendar: calendar), provider: .claude, model: model, tokens: tokens, dedupeKey: key,
                tier: usage.speed == "fast" ? .fast : .standard,
                multiplier: usage.inference_geo == "us" ? Pricing.usInferenceMultiplier : 1,
                webSearches: usage.server_tool_use?.web_search_requests ?? 0))
        }
        return entries
    }

    // MARK: Codex

    private struct CodexLine: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable {
                var total_token_usage: Counts?
                var last_token_usage: Counts?
            }
            struct ThreadSettings: Decodable {
                var service_tier: String?
            }
            var type: String?
            var info: Info?
            var thread_settings: ThreadSettings?
        }
        var timestamp: String?
        var type: String?
        var payload: Payload?
    }

    struct Counts: Decodable, Equatable {
        var input_tokens: Int?
        var cached_input_tokens: Int?
        var cache_write_input_tokens: Int?
        var output_tokens: Int?

        static func - (lhs: Counts, rhs: Counts) -> Counts {
            Counts(input_tokens: (lhs.input_tokens ?? 0) - (rhs.input_tokens ?? 0),
                   cached_input_tokens: (lhs.cached_input_tokens ?? 0) - (rhs.cached_input_tokens ?? 0),
                   cache_write_input_tokens: (lhs.cache_write_input_tokens ?? 0) - (rhs.cache_write_input_tokens ?? 0),
                   output_tokens: (lhs.output_tokens ?? 0) - (rhs.output_tokens ?? 0))
        }

        var isNegative: Bool {
            [input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens].contains { ($0 ?? 0) < 0 }
        }

        /// Codex counts cached tokens inside `input_tokens` and reasoning
        /// inside `output_tokens`.
        var usage: TokenUsage {
            let cached = cached_input_tokens ?? 0
            let writes = cache_write_input_tokens ?? 0
            return TokenUsage(input: max(0, (input_tokens ?? 0) - cached - writes), output: output_tokens ?? 0,
                              cacheRead: cached, cacheWrite5m: writes)
        }
    }

    /// Token deltas from one `~/.codex/sessions/**/rollout-*.jsonl`. Totals
    /// are cumulative, so each event counts what grew since the last one; the
    /// first event of a file uses its own last-turn figure, since a resumed
    /// session carries the earlier totals over. The service tier set by the
    /// latest thread settings (priority costs more) applies to the turns
    /// after it.
    public static func codex(_ data: Data, calendar: Calendar = .current) -> [UsageEntry] {
        let decoder = JSONDecoder()
        var entries: [UsageEntry] = []
        var model = "gpt-5"
        var tier = PriceTier.standard
        var previous: Counts?
        // Codex writes the event type within a line's first ~150 bytes, so
        // only line heads are searched; the rest of a 2 GB month is skipped.
        forEachLine(in: data, headContainsAny: [#""type":"turn_context""#, #""token_count""#,
                                                #""thread_settings_applied""#]) { line in
            // Turn contexts carry the whole system prompt; read just the model.
            if line.range(of: Data(#""type":"turn_context""#.utf8)) != nil {
                if let name = firstString(after: #""model":""#, in: line), !name.isEmpty { model = name }
                return
            }
            guard let parsed = try? decoder.decode(CodexLine.self, from: line), let payload = parsed.payload else { return }
            if payload.type == "thread_settings_applied" {
                tier = Self.codexTier(payload.thread_settings?.service_tier)
                return
            }
            guard payload.type == "token_count", let info = payload.info,
                  let date = parsed.timestamp.flatMap(Timestamps.parse) else { return }
            let delta: Counts?
            if let total = info.total_token_usage {
                if let previous, !(total - previous).isNegative {
                    delta = total - previous
                } else {
                    delta = info.last_token_usage
                }
                previous = total
            } else {
                delta = info.last_token_usage
            }
            guard let tokens = delta?.usage, !tokens.isEmpty else { return }
            entries.append(UsageEntry(day: Day(date, calendar: calendar), provider: .codex,
                                      model: model, tokens: tokens, dedupeKey: nil, tier: tier,
                                      promptTokens: info.last_token_usage?.input_tokens))
        }
        return entries
    }

    /// The string value right after `prefix` (a JSON key and opening quote).
    /// Raw JSON escapes quotes inside strings, so a match is a real key.
    static func firstString(after prefix: String, in line: Data) -> String? {
        guard let start = line.range(of: Data(prefix.utf8))?.upperBound,
              let end = line[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: line[start..<end], as: UTF8.self)
    }

    static func codexTier(_ value: String?) -> PriceTier {
        switch value {
        case "priority", "fast": .priority
        case "flex": .flex
        default: .standard
        }
    }

    // MARK: Lines

    /// Calls `body` with each line holding all `needles`, in file order.
    private static func forEachLine(in data: Data, containing needles: [String], _ body: (Data) -> Void) {
        guard let first = needles.first else { return }
        let rest = needles.dropFirst().map { Data($0.utf8) }
        for range in lineRanges(in: data, matching: [first]) {
            let line = data[range]
            if rest.allSatisfy({ line.range(of: $0) != nil }) { body(line) }
        }
    }

    /// Calls `body` with each line whose first `headLength` bytes hold any
    /// of `needles`, in file order.
    private static func forEachLine(in data: Data, headContainsAny needles: [String], headLength: Int = 256,
                                    _ body: (Data) -> Void) {
        let patterns = needles.map { Array($0.utf8) }
        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var cursor = buffer.baseAddress else { return }
            let base = cursor
            var left = buffer.count
            while left > 0 {
                let length = memchr(cursor, Int32(UInt8(ascii: "\n")), left).map { cursor.distance(to: $0) } ?? left
                let head = min(length, headLength)
                if patterns.contains(where: { ByteSearch.find($0, in: cursor, count: head) != nil }) {
                    let start = base.distance(to: cursor)
                    ranges.append(start..<start + length)
                }
                cursor += min(length + 1, left)
                left -= min(length + 1, left)
            }
        }
        let origin = data.startIndex
        for range in ranges { body(data[(origin + range.lowerBound)..<(origin + range.upperBound)]) }
    }

    /// Ranges of the lines containing any needle. ByteSearch jumps between
    /// matches, so the bulk of a log (tool output, file contents) is never
    /// walked line by line.
    static func lineRanges(in data: Data, matching needles: [String]) -> [Range<Data.Index>] {
        var starts = Set<Int>()
        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            let count = buffer.count
            for needle in needles {
                let pattern = Array(needle.utf8)
                var offset = 0
                while offset < count, let hit = ByteSearch.find(pattern, in: base + offset, count: count - offset) {
                    let at = base.distance(to: hit)
                    var lineStart = at
                    while lineStart > 0, buffer[lineStart - 1] != UInt8(ascii: "\n") { lineStart -= 1 }
                    let rest = count - at
                    let newline = memchr(hit, Int32(UInt8(ascii: "\n")), rest)
                    let lineEnd = newline.map { base.distance(to: $0) } ?? count
                    if starts.insert(lineStart).inserted { ranges.append(lineStart..<lineEnd) }
                    offset = lineEnd + 1
                }
            }
        }
        let origin = data.startIndex
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
            .map { (origin + $0.lowerBound)..<(origin + $0.upperBound) }
    }
}

enum Timestamps {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func parse(_ text: String) -> Date? {
        lock.withLock { fractional.date(from: text) ?? plain.date(from: text) }
    }
}
