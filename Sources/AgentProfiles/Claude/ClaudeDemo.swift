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
        } catch {
            NSLog("[Agent Profiles] Claude preview setup failed: %@", error.localizedDescription)
        }
        return home
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
