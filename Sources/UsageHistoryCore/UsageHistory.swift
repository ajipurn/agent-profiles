import Foundation
import PlatformSupport

/// One reading of an account's usage limits: the used share of each window,
/// as the provider reported it at `at`.
public struct UsageSample: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case claude, codex
    }

    public var provider: Provider
    /// The Claude profile's name, or the Codex account's id.
    public var account: String
    /// When the numbers were current: Claude's own fetch, or Codex's.
    public var at: Date
    /// Used share of the session (5-hour) and weekly windows, 0–100.
    public var session: Double?
    public var weekly: Double?

    public init(provider: Provider, account: String, at: Date, session: Double?, weekly: Double?) {
        self.provider = provider
        self.account = account
        self.at = at
        self.session = session
        self.weekly = weekly
    }

    // Short keys: a month of readings is tens of thousands of lines.
    enum CodingKeys: String, CodingKey {
        case provider = "p", account = "a", at = "t", session = "s", weekly = "w"
    }
}

/// The readings the app has seen, one JSON line each, kept for a month in
/// `<app data>/AgentProfiles/usage-history.jsonl`. Nothing leaves the Mac.
public actor UsageHistory {
    public static let retention: TimeInterval = 30 * 86_400
    /// Readings closer together than this add nothing to a chart of days.
    public static let spacing: TimeInterval = 10 * 60

    public let file: URL
    private var newest: [String: Date] = [:]
    private var loaded = false

    public init(file: URL) {
        self.file = file
    }

    public init(home: URL) {
        self.init(file: PlatformPaths.appData(home: home)
            .appendingPathComponent("AgentProfiles/usage-history.jsonl"))
    }

    /// Keeps each reading that comes at least `spacing` after the account's
    /// newest one; repeats of what was already kept are dropped.
    public func record(_ samples: [UsageSample]) {
        loadOnce()
        var kept: [UsageSample] = []
        for sample in samples.sorted(by: { $0.at < $1.at }) where sample.session != nil || sample.weekly != nil {
            let key = Self.key(sample)
            if let newest = newest[key], sample.at < newest.addingTimeInterval(Self.spacing) { continue }
            newest[key] = sample.at
            kept.append(sample)
        }
        guard !kept.isEmpty else { return }
        do {
            try append(kept)
        } catch {
            NSLog("[Agent Profiles] Usage history not saved: %@", error.localizedDescription)
        }
    }

    /// Every reading since `date`, oldest first.
    public func samples(since date: Date) -> [UsageSample] {
        read().filter { $0.at >= date }
    }

    /// Replaces the whole history; preview mode seeds its sample accounts with it.
    public func replace(with samples: [UsageSample]) throws {
        try write(samples.sorted { $0.at < $1.at })
        newest = [:]
        loaded = false
    }

    // MARK: - File

    static func key(_ sample: UsageSample) -> String { sample.provider.rawValue + "/" + sample.account }

    /// Learns each account's newest reading, and drops what is past retention
    /// once per launch.
    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        let all = read()
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let current = all.filter { $0.at >= cutoff }
        for sample in current {
            let key = Self.key(sample)
            if newest[key].map({ sample.at > $0 }) ?? true { newest[key] = sample.at }
        }
        if current.count < all.count { try? write(current) }
    }

    private func read() -> [UsageSample] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // A line cut short by a crash is skipped, not the whole file.
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(UsageSample.self, from: Data($0)) }
    }

    private func lines(_ samples: [UsageSample]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        var data = Data()
        for sample in samples {
            data.append(try encoder.encode(sample))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    private func append(_ samples: [UsageSample]) throws {
        let data = try lines(samples)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: file.path) else { return try data.write(to: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func write(_ samples: [UsageSample]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines(samples).write(to: file, options: .atomic)
    }
}
