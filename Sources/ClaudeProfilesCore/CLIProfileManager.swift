import Foundation
import PlatformSupport

/// Claude Code (CLI) profiles. Nothing like the Desktop flow: no symlink, no
/// app lifecycle. Each profile is its own CLAUDE_CONFIG_DIR; Claude Code keeps
/// every config dir's login isolated by itself (its Keychain entries are keyed
/// by the dir's path). A tiny `claude` shim on PATH reads the selected profile
/// name from a text file at every launch, so switching = rewriting that file —
/// it applies to `claude` commands started from then on, never to running ones.
public final class CLIProfileManager: Sendable {
    public let home: URL
    private var fm: FileManager { .default }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    // Lives under the `_` prefix so ProfileManager.profiles() never lists it.
    public var cliDir: URL { PlatformPaths.appData(home: home).appendingPathComponent("Claude-Profiles/_cli") }
    public var profilesDir: URL { cliDir.appendingPathComponent("profiles") }
    public var shim: URL { cliDir.appendingPathComponent("bin/claude") }
    /// Windows' shim: a batch file, which cmd, PowerShell and other programs
    /// all find on PATH as `claude`.
    public var windowsShim: URL { cliDir.appendingPathComponent("bin/claude.cmd") }
    public var profileTool: URL { cliDir.appendingPathComponent("bin/claude-profile") }
    private var activeFile: URL { cliDir.appendingPathComponent("active") }

    /// The one line the user adds to ~/.zshrc. Prepending keeps the shim ahead
    /// of the real binary no matter where it is installed.
    public static let pathLine =
        #"export PATH="\#(shellBase)/bin:$PATH""#

    /// Windows: the PowerShell line that puts the shim first on the user's
    /// PATH. Claude Code installs into the user's own folders, which the user
    /// PATH lists, so first there is ahead of it.
    public static let windowsPathLine =
        #"[Environment]::SetEnvironmentVariable('Path', "$env:APPDATA\Claude-Profiles\_cli\bin;" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')"#

    /// `_cli` as the scripts spell it, so they follow PlatformPaths too.
    static let shellBase = "$HOME/\(PlatformPaths.appDataRelativePath)/Claude-Profiles/_cli"

    public var isSetUp: Bool {
        #if os(Windows)
        fm.fileExists(atPath: windowsShim.path)
        #else
        fm.isExecutableFile(atPath: shim.path)
        #endif
    }

    /// UI-only flag: hides the Default (~/.claude) row. Nothing about the
    /// default account itself changes — the shim still falls back to it.
    public var defaultHidden: Bool {
        (try? fm.attributesOfItem(atPath: cliDir.appendingPathComponent("hide-default").path)) != nil
    }

    public func setDefaultHidden(_ hidden: Bool) throws {
        let flag = cliDir.appendingPathComponent("hide-default")
        if hidden {
            try fm.createDirectory(at: cliDir, withIntermediateDirectories: true)
            try Data().write(to: flag)
        } else {
            try? fm.removeItem(at: flag)
        }
    }

    public func profiles() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: profilesDir.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && isDirectory(profilesDir.appendingPathComponent($0)) }
            .sorted()
    }

    /// nil = the default account: plain ~/.claude, untouched by this app.
    public func activeProfile() -> String? {
        guard let raw = try? String(contentsOf: activeFile, encoding: .utf8) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles().contains(name) ? name : nil
    }

    /// nil switches back to the default account.
    public func setActive(_ name: String?) throws {
        guard let name else {
            try? fm.removeItem(at: activeFile)
            return
        }
        guard profiles().contains(name) else { throw ProfileError.profileNotFound(name) }
        try (name + "\n").write(to: activeFile, atomically: true, encoding: .utf8)
    }

    @discardableResult
    public func createProfile(name rawName: String) throws -> String {
        guard let name = ProfileManager.sanitize(rawName) else { throw ProfileError.invalidName }
        let dir = profilesDir.appendingPathComponent(name)
        guard (try? fm.attributesOfItem(atPath: dir.path)) == nil else { throw ProfileError.profileExists(name) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return name
    }

    /// Renaming moves the config dir — and the dir's *path* is what Claude Code
    /// keys its Keychain entry on, so the renamed profile is logged out and asks
    /// to log in again on its next run. Callers must warn the user first.
    @discardableResult
    public func renameProfile(_ name: String, to rawNewName: String) throws -> String {
        guard let newName = ProfileManager.sanitize(rawNewName) else { throw ProfileError.invalidName }
        guard newName != name else { return name }
        let src = profilesDir.appendingPathComponent(name)
        guard isDirectory(src) else { throw ProfileError.profileNotFound(name) }
        let dst = profilesDir.appendingPathComponent(newName)
        guard (try? fm.attributesOfItem(atPath: dst.path)) == nil else { throw ProfileError.profileExists(newName) }
        let wasActive = activeProfile() == name
        try fm.moveItem(at: src, to: dst)
        if wasActive { try setActive(newName) }
        return newName
    }

    /// Deleting removes the profile's data. Its login token stays orphaned in
    /// the user's Keychain — removing that would mean touching Keychain items,
    /// which this app never does.
    public func deleteProfile(name: String) throws {
        let dir = profilesDir.appendingPathComponent(name)
        guard isDirectory(dir) else { throw ProfileError.profileNotFound(name) }
        if activeProfile() == name { try setActive(nil) }
        try fm.removeItem(at: dir)
    }

    /// Idempotent: safe to re-run, always writes the current scripts.
    public func installShim() throws {
        #if os(Windows)
        try installWindowsShim()
        #else
        try fm.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try Self.shimScript.write(to: shim, atomically: true, encoding: .utf8)
        try FilePermissions.set(0o755, at: shim)
        try Self.profileToolScript.write(to: profileTool, atomically: true, encoding: .utf8)
        try FilePermissions.set(0o755, at: profileTool)
        #endif
    }

    /// Writes `claude.cmd`; callable on any system so it can be tested.
    func installWindowsShim() throws {
        try fm.createDirectory(at: windowsShim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try Data(Self.windowsShimScript.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: windowsShim)
    }

    /// cmd's version of the shim: the profile named in `..\active` becomes
    /// CLAUDE_CONFIG_DIR unless one is set already, then the next `claude` on
    /// PATH that isn't this file runs with every argument. Lines and gotos
    /// rather than blocks: a block expands %vars% before it runs, and delayed
    /// expansion would eat a `!` in the arguments.
    static let windowsShimScript = #"""
        @echo off
        setlocal DisableDelayedExpansion
        set "SHIM_DIR=%~dp0"
        if defined CLAUDE_CONFIG_DIR goto run
        if not exist "%SHIM_DIR%..\active" goto run
        set "ACTIVE="
        set /p ACTIVE=<"%SHIM_DIR%..\active"
        if not defined ACTIVE goto run
        if not exist "%SHIM_DIR%..\profiles\%ACTIVE%\" goto run
        for %%I in ("%SHIM_DIR%..\profiles\%ACTIVE%") do set "CLAUDE_CONFIG_DIR=%%~fI"
        :run
        for /f "delims=" %%C in ('where claude 2^>nul') do if /i not "%%~dpC"=="%SHIM_DIR%" (
          set "TARGET=%%C"
          goto found
        )
        echo claude: no Claude Code found on PATH besides this profile shim 1>&2
        exit /b 9009
        :found
        "%TARGET%" %*
        exit /b %ERRORLEVEL%
        """#

    private func isDirectory(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    static let shimScript = """
    #!/bin/sh
    # Claude Profiles CLI shim — runs `claude` as the profile picked in the
    # menu bar app. An explicit CLAUDE_CONFIG_DIR (env or alias) always wins,
    # and the Default profile leaves everything untouched (plain ~/.claude).
    base="\(shellBase)"
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$base/active" ]; then
        IFS= read -r name < "$base/active"
        if [ -n "$name" ] && [ -d "$base/profiles/$name" ]; then
            CLAUDE_CONFIG_DIR="$base/profiles/$name"
            export CLAUDE_CONFIG_DIR
        fi
    fi
    # exec the first `claude` on PATH that is not this shim
    self="$base/bin/claude"
    IFS='
    '
    for real in $(which -a claude 2>/dev/null); do
        if [ "$real" = "$self" ] || [ "$real" -ef "$self" ]; then continue; fi
        exec "$real" "$@"
    done
    echo "claude (Claude Profiles shim): real claude not found in PATH" >&2
    exit 127
    """

    static let profileToolScript = """
    #!/bin/sh
    # Claude Profiles — switch the profile `claude` uses, from the terminal.
    # Same effect as clicking a terminal icon in the menu bar app: rewrites
    # _cli/active, which the `claude` shim reads at every launch. Applies to
    # claude commands started from now on, never to ones already running.
    base="\(shellBase)"
    case "${1:-}" in
    "")
        name=""
        if [ -f "$base/active" ]; then IFS= read -r name < "$base/active"; fi
        if [ -n "$name" ] && [ -d "$base/profiles/$name" ]; then
            echo "$name"
        else
            echo "default"
        fi
        ;;
    # `list`/`help` shadow profiles with those exact names — switch those in the app.
    list|-l|--list)
        echo "default"
        ls "$base/profiles" 2>/dev/null
        ;;
    help|-h|--help)
        echo "usage: claude-profile           show the active CLI profile"
        echo "       claude-profile <name>    switch to <name> (new claude runs only)"
        echo "       claude-profile default   back to the plain ~/.claude account"
        echo "       claude-profile list      list available profiles"
        ;;
    *)
        # A real profile dir wins over the `default` keyword.
        if [ -d "$base/profiles/$1" ]; then
            printf '%s\\n' "$1" > "$base/active"
            echo "CLI profile: $1 — applies to claude commands started from now on"
        elif [ "$1" = "default" ]; then
            rm -f "$base/active"
            echo "CLI profile: default (~/.claude) — applies to claude commands started from now on"
        else
            echo "claude-profile: no profile named '$1'" >&2
            { echo "profiles:"; echo "  default"; ls "$base/profiles" 2>/dev/null | sed 's/^/  /'; } >&2
            exit 1
        fi
        ;;
    esac
    """
}
