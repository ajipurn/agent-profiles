import Foundation

public struct CodexCLI {
    public var executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public static func resolve() -> CodexCLI? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".volta/bin/codex").path,
            home.appendingPathComponent(".bun/bin/codex").path,
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
            })
        }

        let nvmVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions.map {
                $0.appendingPathComponent("bin/codex").path
            })
        }

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted
            && FileManager.default.isExecutableFile(atPath: path)
        {
            return CodexCLI(executable: URL(fileURLWithPath: path))
        }
        return nil
    }

    public func logout() throws {
        try run(arguments: ["logout"])
    }

    public func login() throws {
        try run(arguments: ["login"])
    }

    func run(arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw SwitcherError.loginFailed("codex \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        }
    }
}
