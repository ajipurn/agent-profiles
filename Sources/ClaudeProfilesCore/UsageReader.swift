import Foundation
import CZstd
import PlatformSupport

/// The official usage-limit numbers for one account: read from the profile's
/// own HTTP cache (what Claude Desktop last saw), or asked for live with
/// Claude's own sign-in (see `DesktopLogin`).
public struct ProfileUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let percent: Double
        public let resetsAt: Date?
        /// A window whose reset time has passed says nothing about now.
        public var expired: Bool { expired(at: Date()) }

        public func expired(at now: Date) -> Bool {
            guard let resetsAt else { return false }
            return resetsAt < now
        }
    }

    /// A weekly window that covers only some models ("Sonnet", "Opus").
    public struct ScopedWindow: Equatable, Sendable {
        public let name: String
        public let window: Window
    }

    /// Pay-as-you-go spend beyond the plan, in the account's currency.
    public struct ExtraUsage: Equatable, Sendable {
        public let used: Double
        /// Monthly cap; nil when none is set.
        public let limit: Double?
        public let currency: String
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    public var scoped: [ScopedWindow] = []
    public var extraUsage: ExtraUsage?
    /// When these numbers were fetched (cache entry mtime, or the live answer).
    public let asOf: Date
    public let orgID: String
    /// False for `?skip_spend=1` responses, which leave `extra_usage` out.
    var spendIncluded = true

    init(fiveHour: Window?, sevenDay: Window?, scoped: [ScopedWindow] = [], extraUsage: ExtraUsage? = nil,
         asOf: Date, orgID: String, spendIncluded: Bool = true) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.scoped = scoped
        self.extraUsage = extraUsage
        self.asOf = asOf
        self.orgID = orgID
        self.spendIncluded = spendIncluded
    }
}

/// Finds the cached `GET /api/organizations/<org>/usage` response inside a
/// profile's `Cache/Cache_Data` and decodes it. Chromium "simple cache" entry
/// layout (verified against real files): 20-byte header (8 magic, 4 version,
/// 4 key length, 4 key hash), the key string, then the response body — which
/// claude.ai serves zstd-compressed.
///
/// All of this is Anthropic/Chromium internals and can change under us, so
/// every step fails soft: anything unexpected just means "no usage info".
public enum UsageReader {
    static let entryMagic: [UInt8] = [0x30, 0x5C, 0x72, 0xA7, 0x1B, 0x6D, 0xFB, 0xFC]
    // Usage responses are ~3 KB; skipping bigger files keeps the scan cheap.
    static let maxEntrySize = 64 * 1024

    /// Parse results keyed by file path, so the 60-second poll only re-reads
    /// entries whose (mtime, size) changed. `usage == nil` remembers "not a
    /// usage entry" — the common case for most cache files. Behind a lock:
    /// profiles are scanned concurrently.
    private struct ParsedEntry: Sendable {
        let mtime: Date
        let size: Int
        let usage: ProfileUsage?
    }
    private static let parsedCache = LockedValue([String: ParsedEntry]())

    /// Newest cached usage snapshot in `dir`. When `orgIDs` is non-empty and
    /// any entry matches one of them, only those entries are considered — a
    /// profile's cache can retain responses for orgs it no longer uses.
    public static func usage(inProfileDir dir: URL, orgIDs: Set<String> = []) -> ProfileUsage? {
        let cacheDir = dir.appendingPathComponent("Cache/Cache_Data")
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }

        var found: [ProfileUsage] = []
        var seen: Set<String> = []
        for file in files where file.lastPathComponent.hasSuffix("_0") {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize, size <= maxEntrySize,
                  let mtime = values.contentModificationDate
            else { continue }
            seen.insert(file.path)

            let hit = parsedCache.withLock { $0[file.path] }
            if let hit, hit.mtime == mtime, hit.size == size {
                if let usage = hit.usage { found.append(usage) }
                continue
            }

            let parsed: ProfileUsage?
            if let data = try? Data(contentsOf: file),
               let entry = parseUsageEntry(data) {
                parsed = decode(body: entry.body, orgID: entry.org, asOf: mtime, spendIncluded: entry.spendIncluded)
            } else {
                parsed = nil
            }
            let entry = ParsedEntry(mtime: mtime, size: size, usage: parsed)
            parsedCache.withLock { $0[file.path] = entry }
            if let parsed { found.append(parsed) }
        }

        // Evicted cache files must not pin stale results (or memory).
        let prefix = cacheDir.path + "/"
        let live = seen
        parsedCache.withLock { cache in
            for key in cache.keys where key.hasPrefix(prefix) && !live.contains(key) {
                cache.removeValue(forKey: key)
            }
        }

        let matching = found.filter { orgIDs.contains($0.orgID) }
        let pool = (orgIDs.isEmpty || matching.isEmpty) ? found : matching
        guard var newest = pool.max(by: { $0.asOf < $1.asOf }) else { return nil }
        // A `skip_spend` response says nothing about extra usage; keep what
        // the newest full response for the same org said (Claude does too).
        if !newest.spendIncluded {
            newest.extraUsage = pool
                .filter { $0.spendIncluded && $0.orgID == newest.orgID }
                .max { $0.asOf < $1.asOf }?.extraUsage
        }
        return newest
    }

    struct UsageEntry {
        let org: String
        let body: Data
        let spendIncluded: Bool
    }

    /// Returns the org and response body if `data` is a cache entry for /usage.
    static func parseUsageEntry(_ data: Data) -> UsageEntry? {
        // Header: magic u64, version u32, key_length u32, key_hash u32 —
        // padded to 24 bytes on disk (struct alignment), then the key.
        let headerSize = 24
        guard data.count > headerSize, data.prefix(8).elementsEqual(entryMagic) else { return nil }
        let keyLen = Int(data[12]) | Int(data[13]) << 8 | Int(data[14]) << 16 | Int(data[15]) << 24
        guard keyLen > 0, keyLen < 4096, data.count > headerSize + keyLen,
              let key = String(data: data[headerSize ..< headerSize + keyLen], encoding: .utf8) else { return nil }
        // Key looks like "1/0/https://claude.ai/api/organizations/<uuid>/usage",
        // optionally with a query: Claude asks for "?skip_spend=1",
        // "?at_wall=1&skip_spend=1", "?source=…" and so on — same body shape.
        guard let range = key.range(of: "/api/organizations/") else { return nil }
        let rest = key[range.upperBound...]
        let org = String(rest.prefix(36))
        let tail = rest.dropFirst(36)
        guard org.count == 36, tail == "/usage" || tail.hasPrefix("/usage?") else { return nil }
        let query = tail.dropFirst("/usage".count)
        let skipsSpend = query.dropFirst().split(separator: "&").contains("skip_spend=1")
        return UsageEntry(org: org, body: data.subdata(in: (headerSize + keyLen) ..< data.count),
                          spendIncluded: !skipsSpend)
    }

    static func decode(body: Data, orgID: String, asOf: Date, spendIncluded: Bool = true) -> ProfileUsage? {
        // The body stream is followed by the entry's EOF record; the zstd
        // decoder stops at the frame end, so trailing bytes are harmless.
        // An uncompressed body (no content-encoding) starts with '{' — there
        // the trailing record must be cut off (JSON parsers reject trailers).
        let json: Data?
        if body.first == UInt8(ascii: "{") {
            json = body.lastIndex(of: UInt8(ascii: "}")).map { Data(body[...$0]) }
        } else if body.prefix(4).elementsEqual([0x28, 0xB5, 0x2F, 0xFD]) {
            json = zstdDecompress(body)
        } else {
            json = nil
        }
        guard let json,
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }

        func window(_ key: String) -> ProfileUsage.Window? {
            guard let raw = obj[key] as? [String: Any],
                  let percent = number(raw["utilization"]) else { return nil }
            return .init(percent: percent, resetsAt: (raw["resets_at"] as? String).flatMap(parseISO))
        }
        let five = window("five_hour")
        let seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return ProfileUsage(fiveHour: five, sevenDay: seven,
                            scoped: scopedWindows(obj, legacy: window),
                            extraUsage: spendIncluded ? extraUsage(obj["extra_usage"]) : nil,
                            asOf: asOf, orgID: orgID, spendIncluded: spendIncluded)
    }

    /// Per-model weekly windows. Older responses name them `seven_day_sonnet`
    /// and `seven_day_opus`; newer ones list `kind: "weekly_scoped"` entries in
    /// `limits` with the model's display name. Either way, one per model.
    static func scopedWindows(_ obj: [String: Any], legacy: (String) -> ProfileUsage.Window?) -> [ProfileUsage.ScopedWindow] {
        var found: [ProfileUsage.ScopedWindow] = []
        func add(_ name: String, _ window: ProfileUsage.Window?) {
            guard let window, !found.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            found.append(.init(name: name, window: window))
        }
        for entry in obj["limits"] as? [Any] ?? [] {
            guard let limit = entry as? [String: Any], limit["kind"] as? String == "weekly_scoped",
                  let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let percent = number(limit["percent"]) else { continue }
            add(name, .init(percent: percent, resetsAt: (limit["resets_at"] as? String).flatMap(parseISO)))
        }
        add("Sonnet", legacy("seven_day_sonnet"))
        add("Opus", legacy("seven_day_opus"))
        return found
    }

    /// `extra_usage` amounts are in minor units (cents) with `decimal_places`.
    static func extraUsage(_ value: Any?) -> ProfileUsage.ExtraUsage? {
        guard let object = value as? [String: Any], object["is_enabled"] as? Bool == true else { return nil }
        let scale = pow(10, number(object["decimal_places"]) ?? 2)
        let limit = number(object["monthly_limit"]).flatMap { $0 > 0 ? $0.rounded() / scale : nil }
        return .init(used: (number(object["used_credits"]) ?? 0).rounded() / scale,
                     limit: limit,
                     currency: (object["currency"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "USD")
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Streaming decompress of one zstd frame; trailing input is ignored.
    static func zstdDecompress(_ input: Data, maxOutput: Int = 4 << 20) -> Data? {
        guard let zds = ZSTD_createDStream() else { return nil }
        defer { _ = ZSTD_freeDStream(zds) }
        _ = ZSTD_initDStream(zds)

        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            var inBuf = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
            while true {
                var status = 0 // 0 = keep going, 1 = frame done, 2 = fail
                chunk.withUnsafeMutableBytes { ob in
                    var outBuf = ZSTD_outBuffer(dst: ob.baseAddress, size: ob.count, pos: 0)
                    let code = ZSTD_decompressStream(zds, &outBuf, &inBuf)
                    if ZSTD_isError(code) != 0 { status = 2; return }
                    out.append(ob.bindMemory(to: UInt8.self).baseAddress!, count: outBuf.pos)
                    if code == 0 { status = 1 }                                  // frame complete
                    else if outBuf.pos == 0, inBuf.pos == inBuf.size { status = 2 } // stuck
                }
                if status == 2 || out.count > maxOutput { return nil }
                if status == 1 { return out }
            }
        }
    }
}
