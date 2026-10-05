import Foundation
import Testing
@testable import ClaudeProfilesCore

final class CLIProfileManagerTests {
    let fm = FileManager.default
    var home: URL!
    var cli: CLIProfileManager!

    init() throws {
        home = fm.temporaryDirectory.appendingPathComponent("claude-cli-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        cli = CLIProfileManager(home: home)
    }

    deinit {
        try? fm.removeItem(at: home)
    }

    @Test func testFreshStateIsDefault() {
        #expect(!cli.isSetUp)
        #expect(cli.profiles() == [])
        #expect(cli.activeProfile() == nil)
    }

    @Test func testInstallShimIsIdempotentAndExecutable() throws {
        try cli.installShim()
        try cli.installShim()
        #expect(cli.isSetUp)
        #if os(Windows)
        // One launcher under both names.
        #expect(cli.shim.lastPathComponent == "claude.exe")
        #expect(cli.profileTool.lastPathComponent == "claude-profile.exe")
        let launcher = try #require(fm.contents(atPath: cli.shim.path))
        #expect(!launcher.isEmpty)
        #expect(fm.contents(atPath: cli.profileTool.path) == launcher)

        // An older copy is replaced, and what replacing a running one left behind goes.
        try Data("stale".utf8).write(to: cli.shim)
        let leftover = cli.shim.deletingLastPathComponent().appendingPathComponent("claude.exe.old-1")
        try Data("old".utf8).write(to: leftover)
        try cli.installShim()
        #expect(fm.contents(atPath: cli.shim.path) == launcher)
        #expect(!fm.fileExists(atPath: leftover.path))
        #else
        #expect(fm.isExecutableFile(atPath: cli.shim.path))
        let script = try String(contentsOf: cli.shim, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains("CLAUDE_CONFIG_DIR"))
        #expect(fm.isExecutableFile(atPath: cli.profileTool.path))
        #expect(try String(contentsOf: cli.profileTool, encoding: .utf8).hasPrefix("#!/bin/sh"))
        #endif
    }

    /// The claude-profile script must agree with CLIProfileManager about the
    /// active-file format: names it writes are names the manager reads back.
    @Test func testProfileToolScriptRoundTripsWithManager() throws {
        try cli.installShim()
        try cli.createProfile(name: "work")

        func run(_ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = cli.profileTool
            p.arguments = args
            p.environment = environment()
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            return p.terminationStatus
        }

        #expect(try run(["work"]) == 0)
        #expect(cli.activeProfile() == "work")
        #expect(try run(["default"]) == 0)
        #expect(cli.activeProfile() == nil)
        #expect(try run(["ghost"]) != 0)
        #expect(cli.activeProfile() == nil) // failed switch changes nothing
    }

    /// The shim runs the real claude, never itself, as the selected profile.
    /// An explicit CLAUDE_CONFIG_DIR stays, and arguments and the exit code
    /// pass through untouched.
    @Test func testShimRunsRealClaudeAsSelectedProfile() throws {
        try cli.installShim()
        try cli.createProfile(name: "work")
        let fakeBin = try makeFakeClaude()
        let bin = nativePath(cli.shim.deletingLastPathComponent())
        // The shim's own folder comes first, as the PATH setup puts it.
        let path = [bin, nativePath(fakeBin)] + systemPath
        #if os(Windows)
        let typed = #"--print "hello world""#
        #else
        let typed = "--print|hello world|"
        #endif

        var result = try run(cli.shim, ["--print", "hello world"], environment(path: path))
        #expect(result.status == 7)
        #expect(result.output["config"] == "") // Default: plain ~/.claude
        #expect(result.output["args"] == typed)

        try cli.setActive("work")
        result = try run(cli.shim, [], environment(path: path))
        #expect(result.status == 7)
        #expect(samePath(result.output["config"], cli.profilesDir.appendingPathComponent("work")))

        let explicit = nativePath(home.appendingPathComponent("explicit"))
        result = try run(cli.shim, [], environment(path: path, ["CLAUDE_CONFIG_DIR": explicit]))
        #expect(result.output["config"] == explicit)

        result = try run(cli.shim, [], environment(path: [bin] + systemPath))
        #expect(result.status == 127) // only itself on PATH
    }

    #if os(Windows)
    /// A claude.exe, the native installer's kind, gets the command line
    /// exactly as typed, quotes and all. A copy of cmd.exe stands in for it.
    @Test func testShimHandsCommandLineToRealExecutable() throws {
        try cli.installShim()
        try cli.createProfile(name: "work")
        try cli.setActive("work")
        let fakeBin = home.appendingPathComponent("fake-exe")
        try fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: systemPath[0] + "\\cmd.exe"),
                        to: fakeBin.appendingPathComponent("claude.exe"))
        let path = [nativePath(cli.shim.deletingLastPathComponent()), nativePath(fakeBin)] + systemPath

        let result = try run(cli.shim, ["/d", "/c", "echo config=%CLAUDE_CONFIG_DIR%& exit 5"], environment(path: path))
        #expect(result.status == 5)
        #expect(samePath(result.output["config"], cli.profilesDir.appendingPathComponent("work")))
    }
    #endif

    @Test func testCreateListSwitchDelete() throws {
        try cli.createProfile(name: "work")
        try cli.createProfile(name: "personal")
        #expect(cli.profiles() == ["personal", "work"])

        try cli.setActive("work")
        #expect(cli.activeProfile() == "work")
        try cli.setActive(nil)
        #expect(cli.activeProfile() == nil)

        // Deleting the active profile falls back to the default account.
        try cli.setActive("personal")
        try cli.deleteProfile(name: "personal")
        #expect(cli.activeProfile() == nil)
        #expect(cli.profiles() == ["work"])
    }

    @Test func testDeleteAllDesktopAndCLIProfiles() throws {
        let desktop = ProfileManager(home: home)
        try desktop.migrate(name: "main")
        try cli.createProfile(name: "main")
        try cli.createProfile(name: "cli-only")
        try cli.setActive("main")
        let defaultConfig = home.appendingPathComponent(".claude/settings.json")
        try fm.createDirectory(at: defaultConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "default-data".write(to: defaultConfig, atomically: true, encoding: .utf8)

        try desktop.deleteProfile(name: "main")
        try cli.deleteProfile(name: "main")
        #expect(desktop.profiles().isEmpty)
        #expect(cli.profiles() == ["cli-only"])
        #expect(cli.activeProfile() == nil)
        try cli.setActive("cli-only")
        try cli.deleteProfile(name: "cli-only")

        #expect(cli.profiles().isEmpty)
        #expect(cli.activeProfile() == nil)
        #expect(desktop.claudeDirState() == .missing)
        #expect(try String(contentsOf: defaultConfig, encoding: .utf8) == "default-data")
    }

    @Test func testRenameMovesDirAndFollowsActive() throws {
        try cli.createProfile(name: "old")
        try cli.setActive("old")
        #expect(try cli.renameProfile("old", to: "new") == "new")
        #expect(cli.profiles() == ["new"])
        #expect(cli.activeProfile() == "new")
        #expect(throws: (any Error).self) { try cli.renameProfile("ghost", to: "x") }
        try cli.createProfile(name: "other")
        #expect(throws: (any Error).self) { try cli.renameProfile("new", to: "other") }
    }

    @Test func testRejectsBadNamesAndDuplicates() throws {
        try cli.createProfile(name: "work")
        #expect(throws: (any Error).self) { try cli.createProfile(name: "work") }
        #expect(throws: (any Error).self) { try cli.createProfile(name: "!!!") }
        #expect(throws: (any Error).self) { try cli.setActive("missing") }
        #expect(throws: (any Error).self) { try cli.deleteProfile(name: "missing") }
    }

    @Test func testHideDefaultIsUIOnlyAndReversible() throws {
        #expect(!cli.defaultHidden)
        try cli.setDefaultHidden(true)
        #expect(cli.defaultHidden)
        #expect(cli.activeProfile() == nil) // selection untouched
        try cli.setDefaultHidden(false)
        #expect(!cli.defaultHidden)
    }

    @Test func testUnknownNameInActiveFileMeansDefault() throws {
        try cli.installShim()
        try "stale-profile\n".write(to: cli.cliDir.appendingPathComponent("active"),
                                    atomically: true, encoding: .utf8)
        #expect(cli.activeProfile() == nil)
    }

    @Test func testCLIDirHiddenFromDesktopProfiles() throws {
        try cli.createProfile(name: "work")
        let desktop = ProfileManager(home: home)
        try fm.createDirectory(at: desktop.profilesDir.appendingPathComponent("main"),
                               withIntermediateDirectories: true)
        #expect(desktop.profiles() == ["main"])
    }

    // MARK: - Running the shims

    /// Exactly what the shims get to see: this test's home and, if given,
    /// this PATH. Windows programs also need SystemRoot, and cmd ComSpec.
    func environment(path: [String]? = nil, _ extra: [String: String] = [:]) -> [String: String] {
        var environment = extra
        environment["HOME"] = home.path
        #if os(Windows)
        for name in ["SystemRoot", "ComSpec"] { environment[name] = currentVariable(name) }
        if let path { environment["PATH"] = path.joined(separator: ";") }
        #else
        if let path { environment["PATH"] = path.joined(separator: ":") }
        #endif
        return environment
    }

    /// Folders the shims rely on: `which` and friends, or cmd.exe.
    var systemPath: [String] {
        #if os(Windows)
        [(currentVariable("SystemRoot") ?? #"C:\Windows"#) + #"\System32"#]
        #else
        ["/usr/bin", "/bin"]
        #endif
    }

    func currentVariable(_ name: String) -> String? {
        ProcessInfo.processInfo.environment.first { $0.key.uppercased() == name.uppercased() }?.value
    }

    /// A path as the shims spell it: on Windows, a drive letter and backslashes.
    func nativePath(_ url: URL) -> String {
        #if os(Windows)
        var path = url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
            .replacingOccurrences(of: "/", with: #"\"#)
        if path.hasPrefix(#"\"#), path.dropFirst(2).first == ":" { path.removeFirst() }
        return path
        #else
        return url.path
        #endif
    }

    func samePath(_ printed: String?, _ url: URL) -> Bool {
        #if os(Windows)
        printed?.lowercased() == nativePath(url).lowercased()
        #else
        printed == nativePath(url)
        #endif
    }

    /// A stand-in for the real claude, alone in its folder: it prints
    /// `config=` and `args=` lines about how it was started and exits with 7.
    func makeFakeClaude() throws -> URL {
        let dir = home.appendingPathComponent("fake-bin")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(Windows)
        // A batch file, the way npm installs claude.
        let script = ["@echo off", "echo config=%CLAUDE_CONFIG_DIR%", "echo args=%*", "exit /b 7", ""]
        try script.joined(separator: "\r\n").write(to: dir.appendingPathComponent("claude.cmd"),
                                                   atomically: true, encoding: .utf8)
        #else
        let fake = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        echo "config=${CLAUDE_CONFIG_DIR:-}"
        printf 'args='; printf '%s|' "$@"; echo
        exit 7
        """.write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        #endif
        return dir
    }

    /// Runs `executable` with exactly `environment`, and collects its exit
    /// code and the `key=value` lines it printed.
    func run(_ executable: URL, _ arguments: [String],
             _ environment: [String: String]) throws -> (status: Int32, output: [String: String]) {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var output: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            output[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return (p.terminationStatus, output)
    }
}
