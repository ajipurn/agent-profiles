import Foundation
import PlatformSupport

public struct CodexCLI {
    public var executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public static func resolve() -> CodexCLI? {
        let fm = FileManager.default
        for path in candidatePaths() {
            #if os(Windows)
            let runnable = fm.fileExists(atPath: path) // the .exe/.cmd extension is what makes it runnable
            #else
            let runnable = fm.isExecutableFile(atPath: path)
            #endif
            if runnable { return CodexCLI(executable: URL(fileURLWithPath: path)) }
        }
        return nil
    }

    /// Where codex may live, most preferred first, without duplicates.
    public static func candidatePaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        #if os(Windows)
        // GUI apps get the user's PATH here, which npm, Scoop and WinGet all
        // extend, so PATH comes first; npm's default folder backs it up.
        // Only .exe and .cmd: npm's extensionless `codex` is a Git Bash script.
        let path = environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
        var candidates: [String] = []
        for entry in path.split(separator: ";") {
            var dir = entry.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            while dir.hasSuffix("\\") { dir.removeLast() }
            guard !dir.isEmpty else { continue }
            candidates += ["codex.exe", "codex.cmd"].map { dir + "\\" + $0 }
        }
        candidates.append(PlatformPaths.appData(home: home).appendingPathComponent("npm/codex.cmd").path)
        #else
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex").path,
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".volta/bin/codex").path,
            home.appendingPathComponent(".bun/bin/codex").path,
        ]

        if let path = environment["PATH"] {
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
        #endif

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
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

    /// The Terminal wrapper used by Add Account, also exercised without launching the desktop app.
    public func terminalLoginScript(paths: CodexPaths) -> String {
        """
        #!/bin/zsh
        set -uo pipefail
        umask 077
        MARKER=\(Self.zshSingleQuoted(paths.loginMarker.path))
        STATE=\(Self.zshSingleQuoted(paths.loginState.path))
        PIDFILE=\(Self.zshSingleQuoted(paths.loginProcess.path))
        TTYFILE=\(Self.zshSingleQuoted(paths.loginTTY.path))
        CLI=\(Self.zshSingleQuoted(executable.path))
        export CODEX_HOME=\(Self.zshSingleQuoted(paths.codexHome.path))
        THIS_TTY="$(tty)"
        LOGIN_PID=""

        cleanup() {
          rm -f "$PIDFILE"
        }
        cancelled() {
          if [[ -n "$LOGIN_PID" ]]; then
            kill "$LOGIN_PID" >/dev/null 2>&1 || true
          fi
          printf 'cancelled\\n' > "$STATE"
          exit 130
        }
        trap cleanup EXIT
        trap cancelled HUP INT TERM

        printf '\\033]0;Agent Profiles Login\\007'
        printf '%s\\n' "$THIS_TTY" > "$TTYFILE"
        printf 'running\\n' > "$STATE"
        rm -f "$MARKER"
        echo "Agent Profiles — sign in to the ChatGPT account you want to add."
        echo

        mkdir -p "$CODEX_HOME"
        "$CLI" -c 'cli_auth_credentials_store="file"' login &
        LOGIN_PID=$!
        printf '%s\\n' "$LOGIN_PID" > "$PIDFILE"
        wait "$LOGIN_PID"
        STATUS=$?
        if [[ "$STATUS" -ne 0 ]]; then
          printf 'failed:%s\\n' "$STATUS" > "$STATE"
          exit "$STATUS"
        fi

        touch "$MARKER"
        printf 'succeeded\\n' > "$STATE"
        (
          sleep 0.4
          /usr/bin/osascript - "$THIS_TTY" <<'APPLESCRIPT'
        on run argv
          set ttyName to item 1 of argv
          tell application "Terminal"
            repeat with w in windows
              try
                if (tty of selected tab of w) is ttyName then
                  close w saving no
                end if
              end try
            end repeat
          end tell
        end run
        APPLESCRIPT
        ) >/dev/null 2>&1 &
        disown
        exit 0
        """
    }

    private static func zshSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
