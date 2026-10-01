import Foundation

/// Finds the session logs from the last month, parses the ones that changed
/// since the previous scan, and totals them. Runs off the main thread.
public actor CostScanner {
    public struct Sources: Sendable {
        /// Folders of Claude Code project logs (`<config dir>/projects`).
        public var claude: [URL]
        /// Folders of Codex session logs.
        public var codex: [URL]

        public init(claude: [URL], codex: [URL]) {
            self.claude = claude
            self.codex = codex
        }

        /// The default config dirs plus every Agent Profiles CLI profile.
        public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Sources {
            let fm = FileManager.default
            var claude = [home.appendingPathComponent(".claude/projects"),
                          home.appendingPathComponent(".config/claude/projects")]
            let profiles = home.appendingPathComponent("Library/Application Support/Claude-Profiles/_cli/profiles")
            for name in (try? fm.contentsOfDirectory(atPath: profiles.path)) ?? [] where !name.hasPrefix(".") {
                claude.append(profiles.appendingPathComponent(name).appendingPathComponent("projects"))
            }
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
                ?? home.appendingPathComponent(".codex")
            return Sources(claude: claude, codex: [codexHome.appendingPathComponent("sessions"),
                                                   codexHome.appendingPathComponent("archived_sessions")])
        }
    }

    private struct Parsed {
        var modified: Date
        var size: Int
        var entries: [UsageEntry]
    }

    private let sources: Sources
    private var cache: [String: Parsed] = [:]
    /// Files untouched for longer than this hold nothing for the 30-day view.
    private static let horizon: TimeInterval = 32 * 86_400

    public init(sources: Sources = .standard()) {
        self.sources = sources
    }

    public func scan(now: Date = Date()) -> CostSummary {
        var live = Set<String>()
        var entries: [UsageEntry] = []
        for (roots, provider) in [(sources.claude, CostProvider.claude), (sources.codex, .codex)] {
            for file in Self.logFiles(in: roots, since: now.addingTimeInterval(-Self.horizon)) {
                guard live.insert(file.path).inserted else { continue }
                entries += parsed(file, provider: provider)
            }
        }
        cache = cache.filter { live.contains($0.key) }
        return CostSummary.summarize(entries, now: now)
    }

    private func parsed(_ file: LogFile, provider: CostProvider) -> [UsageEntry] {
        if let hit = cache[file.path], hit.modified == file.modified, hit.size == file.size {
            return hit.entries
        }
        // A plain read beats mapping here: page faults made scans ~5x slower.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)) else { return [] }
        let entries = provider == .claude ? LogParsers.claude(data) : LogParsers.codex(data)
        cache[file.path] = Parsed(modified: file.modified, size: file.size, entries: entries)
        return entries
    }

    struct LogFile {
        var path: String
        var modified: Date
        var size: Int
    }

    /// `.jsonl` files under the roots modified since `cutoff`, each real
    /// file once even when shared history links folders together.
    static func logFiles(in roots: [URL], since cutoff: Date) -> [LogFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var seenRoots = Set<String>()
        var files: [LogFile] = []
        for root in roots {
            let real = root.resolvingSymlinksInPath()
            guard seenRoots.insert(real.path).inserted,
                  let walker = fm.enumerator(at: real, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= cutoff else { continue }
                files.append(LogFile(path: url.resolvingSymlinksInPath().path, modified: modified,
                                     size: values.fileSize ?? 0))
            }
        }
        return files
    }
}
