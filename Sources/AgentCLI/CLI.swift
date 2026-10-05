import Foundation
import CodexProfilesCore

/// `agent-profiles`: the app's state, and its switches, from a terminal
/// (Raycast, Alfred, tmux, Claude Code's status line). Reading comes straight
/// from the files the app keeps. Switching is handed to the app through its
/// URL scheme, so Claude or ChatGPT quits and relaunches exactly as it does
/// from the menu; the command waits until the switch shows on disk.
public enum CLI {
    /// Everything the commands reach outside themselves, so tests can stand in.
    public struct Context: Sendable {
        public var home: URL
        public var codexPaths: CodexPaths
        /// Hands a switch to the app; nil where there is no app yet (Windows, Linux).
        public var openInApp: (@Sendable (URL) throws -> Void)?
        public var fetchCodexUsage: @Sendable (AuthSnapshot) async throws -> UsageFetchResult
        public var output: @Sendable (String) -> Void
        public var errorOutput: @Sendable (String) -> Void
        /// Switching Claude Desktop waits for Claude to quit, up to about 11 s.
        public var switchTimeout: TimeInterval = 30
        public var pollInterval: TimeInterval = 0.25

        public init(
            home: URL,
            codexPaths: CodexPaths,
            openInApp: (@Sendable (URL) throws -> Void)?,
            fetchCodexUsage: @escaping @Sendable (AuthSnapshot) async throws -> UsageFetchResult,
            output: @escaping @Sendable (String) -> Void,
            errorOutput: @escaping @Sendable (String) -> Void
        ) {
            self.home = home
            self.codexPaths = codexPaths
            self.openInApp = openInApp
            self.fetchCodexUsage = fetchCodexUsage
            self.output = output
            self.errorOutput = errorOutput
        }

        public static func live() -> Context {
            let client = CodexUsageClient()
            #if os(macOS)
            let openInApp: (@Sendable (URL) throws -> Void)? = { url in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-g", url.absoluteString] // -g: the frontmost app stays in front
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw CLIError.failed("Agent Profiles could not be reached; is it installed?")
                }
            }
            #else
            let openInApp: (@Sendable (URL) throws -> Void)? = nil
            #endif
            return Context(
                home: FileManager.default.homeDirectoryForCurrentUser,
                codexPaths: .default(),
                openInApp: openInApp,
                fetchCodexUsage: { try await client.fetch(snapshot: $0) },
                output: { print($0) },
                errorOutput: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            )
        }
    }

    /// 0 when done, 1 when it failed, 2 when the command line was wrong.
    public static func run(_ arguments: [String], context: Context) async -> Int32 {
        var words: [String] = []
        var json = false, wait = true, help = false, positionalOnly = false
        for argument in arguments {
            if positionalOnly || !argument.hasPrefix("-") || argument == "-" {
                words.append(argument)
                continue
            }
            switch argument {
            case "--json": json = true
            case "--no-wait": wait = false
            case "-h", "--help": help = true
            case "--": positionalOnly = true // names that start with a dash come after it
            default: return fail(.usage("unknown option \(argument)"), context)
            }
        }
        if help || words.first == "help" {
            context.output(usage)
            return 0
        }
        if words.isEmpty { words = ["status"] }

        let commands = Commands(context: context, json: json)
        do {
            switch (words[0], words.count) {
            case ("status", 1): try commands.status()
            case ("list", 1...2): try commands.list(try words.dropFirst().first.map(provider))
            case ("usage", 1...2): try await commands.usage(try words.dropFirst().first.map(provider))
            case ("cost", 1): await commands.cost()
            case ("switch", 3): try await commands.switchTo(try provider(words[1]), name: words[2], wait: wait)
            case ("switch", _): throw CLIError.usage("switch takes a provider and a name, e.g. switch claude work")
            case (let command, _) where ["status", "list", "usage", "cost"].contains(command):
                throw CLIError.usage("too many arguments for \(command)")
            case (let command, _): throw CLIError.usage("unknown command \(command)")
            }
            return 0
        } catch let error as CLIError {
            return fail(error, context)
        } catch {
            return fail(.failed(error.localizedDescription), context)
        }
    }

    static func provider(_ word: String) throws -> Provider {
        guard let provider = Provider(rawValue: word) else {
            throw CLIError.usage("unknown provider \(word); use claude, claude-cli or codex")
        }
        return provider
    }

    static func fail(_ error: CLIError, _ context: Context) -> Int32 {
        switch error {
        case .usage(let message):
            context.errorOutput("agent-profiles: \(message)\nRun agent-profiles help for the commands.")
            return 2
        case .failed(let message):
            context.errorOutput("agent-profiles: \(message)")
            return 1
        }
    }

    static let usage = """
    usage: agent-profiles [command] [--json]

      status                    the active Claude Desktop profile and its usage, the
                                Claude Code profile and the Codex account (default)
      list [claude|claude-cli|codex]
                                profiles and accounts; * marks the active ones
      usage [claude|codex]      Claude Desktop usage as Claude last saw it, and the
                                active Codex account's usage, fetched now
      cost                      estimated cost today, yesterday and over 30 days,
                                from local Claude Code and Codex logs
      switch claude|claude-cli|codex <name>
                                switch through the Agent Profiles app and wait until
                                it is done (--no-wait returns right away)

      --json                    machine-readable output
    """
}

public enum Provider: String, CaseIterable, Sendable {
    case claude, claudeCLI = "claude-cli", codex

    var title: String {
        switch self {
        case .claude: "Claude Desktop"
        case .claudeCLI: "Claude Code"
        case .codex: "Codex"
        }
    }
}

enum CLIError: Error, Equatable {
    case usage(String)
    case failed(String)
}
