import Foundation
import Testing
@testable import UsageHistoryCore

struct UsageHistoryTests {
    /// On the hour, so half-hour buckets line up with the readings below.
    let start = Date(timeIntervalSince1970: 1_789_999_200)
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-history-tests-\(UUID().uuidString)/usage-history.jsonl")

    func reading(_ account: String, minutes: Double, session: Double? = 10, weekly: Double? = 20,
                 provider: UsageSample.Provider = .claude, from base: Date? = nil) -> UsageSample {
        UsageSample(provider: provider, account: account, at: (base ?? start).addingTimeInterval(minutes * 60),
                    session: session, weekly: weekly)
    }

    @Test func keepsOneReadingPerTenMinutesPerAccount() async throws {
        let now = Date()
        let history = UsageHistory(file: file)
        await history.record([
            reading("work", minutes: 0, from: now), reading("work", minutes: 5, from: now),
            reading("work", minutes: 11, from: now), reading("personal", minutes: 5, from: now),
            reading("work", minutes: 3, from: now), // older than the newest kept: dropped
            reading("work", minutes: 30, session: nil, weekly: nil, from: now), // nothing to keep
        ])
        let kept = await history.samples(since: .distantPast)
        #expect(kept.map(\.account) == ["work", "personal", "work"])
        #expect(kept.map { ($0.at.timeIntervalSince(now) / 60).rounded() } == [0, 5, 11])

        // A new launch reads the file and still knows the newest reading.
        let again = UsageHistory(file: file)
        await again.record([reading("work", minutes: 15, from: now), reading("work", minutes: 25, from: now)])
        #expect(await again.samples(since: .distantPast).count == 4)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func dropsReadingsPastRetentionAndSkipsBrokenLines() async throws {
        let now = Date()
        let old = UsageSample(provider: .codex, account: "id-1", at: now.addingTimeInterval(-31 * 86_400),
                              session: 50, weekly: 60)
        let recent = UsageSample(provider: .codex, account: "id-1", at: now.addingTimeInterval(-86_400),
                                 session: 5, weekly: 6)
        try await UsageHistory(file: file).replace(with: [recent, old])
        // Half a line, as a crash mid-write would leave it.
        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"a":"id-1","p":"co"#.utf8))
        try handle.close()

        let history = UsageHistory(file: file)
        await history.record([UsageSample(provider: .codex, account: "id-1", at: now, session: 7, weekly: 8)])
        let kept = await history.samples(since: .distantPast)
        #expect(kept.map(\.session) == [5, 7])
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func groupsByAccountInTheAppsOrder() {
        let samples = [
            reading("b", minutes: 10), reading("gone", minutes: 0), reading("a", minutes: 5),
            reading("b", minutes: 0), reading("x", minutes: 0, provider: .codex),
        ]
        let groups = AccountHistory.group(samples, provider: .claude, order: ["a", "b", "never-used"])
        #expect(groups.map(\.account) == ["a", "b", "gone"])
        #expect(groups[1].samples.map { $0.at.timeIntervalSince(start) } == [0, 600])
    }

    @Test func countsEachTimeAWindowFilledUp() {
        let values: [Double?] = [40, 99.6, 100, 30, nil, 100, 100, 99]
        let history = AccountHistory(account: "a", samples: values.enumerated().map {
            reading("a", minutes: Double($0.offset * 10), session: $0.element)
        })
        #expect(history.timesFull(.session) == 2)
        #expect(history.peak(.session) == 100)
        #expect(history.peak(.weekly) == 20)
    }

    @Test func breaksLinesAtGapsAndThinsToTheHighest() {
        let history = AccountHistory(account: "a", samples: [
            reading("a", minutes: 0, session: 10), reading("a", minutes: 10, session: 90),
            reading("a", minutes: 20, session: 30), reading("a", minutes: 200, session: 40),
        ])
        #expect(history.segments(gap: 3600).map { $0.count } == [3, 1])
        // Half-hour buckets: 0–10–20 share one, whose highest is 90.
        let thinned = history.thinned(.session, every: 1800)
        #expect(thinned.samples.compactMap(\.session) == [90, 40])
        #expect(history.value(.session, at: start.addingTimeInterval(25 * 60), within: 3600) == 30)
        #expect(history.value(.session, at: start.addingTimeInterval(150 * 60), within: 3600) == nil) // stale
        #expect(history.value(.session, at: start.addingTimeInterval(-60), within: 3600) == nil) // before the first
    }
}
