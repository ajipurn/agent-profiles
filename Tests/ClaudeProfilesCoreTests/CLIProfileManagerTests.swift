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
        #expect(fm.isExecutableFile(atPath: cli.shim.path))
        let script = try String(contentsOf: cli.shim, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains("CLAUDE_CONFIG_DIR"))
        #expect(fm.isExecutableFile(atPath: cli.profileTool.path))
        #expect(try String(contentsOf: cli.profileTool, encoding: .utf8).hasPrefix("#!/bin/sh"))
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
            p.environment = ["HOME": home.path]
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
}
