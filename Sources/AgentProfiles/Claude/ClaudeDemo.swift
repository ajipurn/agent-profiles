import Foundation
import ClaudeProfilesCore

/// Preview data for the Claude side: a throwaway home directory with sample
/// profiles and cached usage, laid out the way Claude Desktop leaves them.
enum ClaudeDemo {
    static func makeHome() -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentProfiles-ClaudeDemo-" + UUID().uuidString)
        let manager = ProfileManager(home: home)
        // Percent of each window already used, like Claude's own /usage payload.
        let samples: [(name: String, fiveHour: Double, sevenDay: Double)] = [
            ("personal", 42, 18), ("work", 91, 64), ("research", 12, 35),
        ]
        do {
            try manager.migrate(name: samples[0].name) // the first one is active
            for sample in samples.dropFirst() {
                try manager.createProfile(name: sample.name)
            }
            for sample in samples {
                try writeUsage(into: manager.profilesDir.appendingPathComponent(sample.name),
                               fiveHourUsed: sample.fiveHour, sevenDayUsed: sample.sevenDay)
            }
            try writeSessionLogs(into: home)
        } catch {
            NSLog("[Agent Profiles] Claude preview setup failed: %@", error.localizedDescription)
        }
        return home
    }

    /// A month of made-up Claude Code and Codex session logs for the Cost
    /// card, in the formats the real CLIs write.
    private static func writeSessionLogs(into home: URL) throws {
        let fm = FileManager.default
        let claudeDir = home.appendingPathComponent(".claude/projects/-demo")
        let codexDir = home.appendingPathComponent(".codex/sessions/demo")
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        var claude: [String] = []
        var codex = [#"{"timestamp":"\#(stamp.string(from: .now))","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#]
        var codexTotal = (input: 0, cached: 0, output: 0)
        for daysAgo in 0..<30 {
            let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400 - 600)
            let scale = daysAgo == 1 ? 1 : (daysAgo % 3) + 1
            for turn in 0..<(4 * scale) {
                let time = stamp.string(from: date.addingTimeInterval(Double(turn) * 60))
                claude.append(#"{"type":"assistant","timestamp":"\#(time)","requestId":"req_\#(daysAgo)_\#(turn)","message":{"id":"msg_\#(daysAgo)_\#(turn)","model":"claude-opus-5-5","usage":{"input_tokens":40,"cache_creation_input_tokens":12000,"cache_read_input_tokens":90000,"output_tokens":1800}}}"#)
                codexTotal.input += 60_000
                codexTotal.cached += 45_000
                codexTotal.output += 900
                codex.append(#"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(codexTotal.input),"cached_input_tokens":\#(codexTotal.cached),"output_tokens":\#(codexTotal.output)}}}}"#)
            }
        }
        try claude.joined(separator: "\n").write(to: claudeDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try codex.joined(separator: "\n").write(to: codexDir.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
    }

    /// One Chromium simple-cache entry holding a `/usage` response, in the
    /// layout UsageReader parses: 24-byte header, key, then an uncompressed
    /// JSON body.
    private static func writeUsage(into profile: URL, fiveHourUsed: Double, sevenDayUsed: Double) throws {
        let cache = profile.appendingPathComponent("Cache/Cache_Data")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let org = UUID().uuidString.lowercased()
        let key = Data("1/0/https://claude.ai/api/organizations/\(org)/usage".utf8)
        let iso = ISO8601DateFormatter()
        let body: [String: Any] = [
            "five_hour": ["utilization": fiveHourUsed,
                          "resets_at": iso.string(from: Date().addingTimeInterval(2 * 3600))],
            "seven_day": ["utilization": sevenDayUsed,
                          "resets_at": iso.string(from: Date().addingTimeInterval(4 * 86_400))],
        ]
        var entry = Data([0x30, 0x5C, 0x72, 0xA7, 0x1B, 0x6D, 0xFB, 0xFC]) // entry magic
        entry.append(contentsOf: le32(5))                 // version
        entry.append(contentsOf: le32(UInt32(key.count))) // key length
        entry.append(contentsOf: le32(0))                 // key hash (not checked)
        entry.append(contentsOf: le32(0))                 // padding to 24 bytes
        entry.append(key)
        entry.append(try JSONSerialization.data(withJSONObject: body))
        try entry.write(to: cache.appendingPathComponent("\(org.prefix(16))_0"))
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
}
