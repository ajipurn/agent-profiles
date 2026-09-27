import Foundation
import Testing
@testable import ClaudeProfilesCore

final class ProfileManagerTests {
    let fm = FileManager.default
    var home: URL!
    var pm: ProfileManager!

    init() throws {
        home = fm.temporaryDirectory.appendingPathComponent("claude-profiles-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        pm = ProfileManager(home: home)
    }

    deinit {
        try? fm.removeItem(at: home)
    }

    // MARK: - Helpers

    func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func makeRealClaudeDir() throws {
        try write("cookie-data", to: pm.claudeDir.appendingPathComponent("Cookies"))
    }

    func itemType(_ url: URL) -> FileAttributeType? {
        (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    func isSymlink(_ url: URL) -> Bool { itemType(url) == .typeSymbolicLink }
    func isRealDir(_ url: URL) -> Bool { itemType(url) == .typeDirectory }

    func profile(_ name: String) -> URL { pm.profilesDir.appendingPathComponent(name) }

    // MARK: - Sanitize

    @Test func testSanitize() {
        #expect(ProfileManager.sanitize("My Profile!") == "MyProfile")
        #expect(ProfileManager.sanitize("work-2_a") == "work-2_a")
        #expect(ProfileManager.sanitize("user@example.com") == "user@example.com")
        #expect(ProfileManager.sanitize("") == nil)
        #expect(ProfileManager.sanitize("💥 ééé") == nil)
    }

    // MARK: - Migration

    @Test func testMigrationMovesRealDirectoryAndSymlinks() throws {
        try makeRealClaudeDir()
        try pm.migrate(name: "main")

        #expect(isSymlink(pm.claudeDir))
        #expect(pm.activeProfile() == "main")
        #expect(try String(contentsOf: profile("main").appendingPathComponent("Cookies"), encoding: .utf8)
            == "cookie-data")
        // Readable through the symlink too.
        #expect(try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8)
            == "cookie-data")
    }

    @Test func testMigrationWithMissingClaudeDirCreatesEmptyProfile() throws {
        try pm.migrate(name: "main")
        #expect(isSymlink(pm.claudeDir))
        #expect(isRealDir(profile("main")))
        #expect(pm.activeProfile() == "main")
    }

    @Test func testMigrationRejectsExistingProfileName() throws {
        try fm.createDirectory(at: profile("main"), withIntermediateDirectories: true)
        try makeRealClaudeDir()

        #expect(throws: ProfileError.profileExists("main")) { try pm.migrate(name: "main") }
        // Untouched.
        #expect(isRealDir(pm.claudeDir))
        #expect(try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8)
            == "cookie-data")
    }

    @Test func testMigrationRejectsInvalidName() throws {
        try makeRealClaudeDir()
        #expect(throws: ProfileError.invalidName) { try pm.migrate(name: "!!!") }
        #expect(isRealDir(pm.claudeDir))
    }

    // MARK: - Switching

    @Test func testSwitchRepointsSymlink() throws {
        try makeRealClaudeDir()
        try pm.migrate(name: "main")
        try pm.createProfile(name: "work")

        try pm.switchTo(name: "work")
        #expect(pm.activeProfile() == "work")

        try pm.switchTo(name: "main")
        #expect(pm.activeProfile() == "main")
        #expect(try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8)
            == "cookie-data")
    }

    @Test func testSwitchNeverClobbersRealDirectory() throws {
        try makeRealClaudeDir()
        try fm.createDirectory(at: profile("work"), withIntermediateDirectories: true)

        #expect(throws: ProfileError.refusedToClobber(pm.claudeDir.path)) { try pm.switchTo(name: "work") }
        #expect(isRealDir(pm.claudeDir))
        #expect(try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8)
            == "cookie-data")
    }

    @Test func testSwitchToMissingProfileThrows() throws {
        try pm.migrate(name: "main")
        #expect(throws: ProfileError.profileNotFound("ghost")) { try pm.switchTo(name: "ghost") }
        #expect(pm.activeProfile() == "main")
    }

    @Test func testSwitchFixesBrokenSymlink() throws {
        try pm.migrate(name: "main")
        try pm.createProfile(name: "work")
        try pm.switchTo(name: "work")

        try fm.removeItem(at: profile("work")) // symlink now dangling

        guard case .symlink(_, false) = pm.claudeDirState() else {
            Issue.record("expected broken symlink, got \(pm.claudeDirState())")
            return
        }
        #expect(pm.activeProfile() == nil)

        try pm.switchTo(name: "main")
        #expect(pm.activeProfile() == "main")
    }

    // MARK: - Listing

    @Test func testProfilesSkipsUnderscoreAndHiddenDirs() throws {
        try fm.createDirectory(at: profile("alpha"), withIntermediateDirectories: true)
        try fm.createDirectory(at: profile("_shared-sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: profile(".hidden"), withIntermediateDirectories: true)
        try write("x", to: profile("not-a-dir.txt"))

        #expect(pm.profiles() == ["alpha"])
    }

    // MARK: - New profile + shared trees

    @Test func testCreateProfilePrelinksSharedTrees() throws {
        for tree in ProfileManager.sessionTrees {
            try fm.createDirectory(at: pm.sharedDir.appendingPathComponent(tree), withIntermediateDirectories: true)
        }
        try pm.createProfile(name: "fresh")

        for tree in ProfileManager.sessionTrees {
            let link = profile("fresh").appendingPathComponent(tree)
            #expect(isSymlink(link), "\(tree) should be pre-linked")
            #expect(try fm.destinationOfSymbolicLink(atPath: link.path)
                == pm.sharedDir.appendingPathComponent(tree).path)
        }
    }

    @Test func testCreateProfileRejectsCollision() throws {
        try pm.createProfile(name: "dup")
        #expect(throws: ProfileError.profileExists("dup")) { try pm.createProfile(name: "dup") }
    }

    // MARK: - Rename / delete

    @Test func testRenameInactiveProfile() throws {
        try pm.migrate(name: "main")
        try pm.createProfile(name: "work")
        try write("x", to: profile("work").appendingPathComponent("marker.txt"))

        #expect(try pm.renameProfile("work", to: "office") == "office")
        #expect(fm.fileExists(atPath: profile("office").appendingPathComponent("marker.txt").path))
        #expect(!fm.fileExists(atPath: profile("work").path))
        #expect(pm.activeProfile() == "main") // untouched
    }

    @Test func testRenameActiveProfileRepointsSymlink() throws {
        try makeRealClaudeDir()
        try pm.migrate(name: "main")
        try pm.renameProfile("main", to: "primary")
        #expect(pm.activeProfile() == "primary")
        #expect(try String(contentsOf: pm.claudeDir.appendingPathComponent("Cookies"), encoding: .utf8)
            == "cookie-data")
    }

    @Test func testRenameRejectsCollisionAndUnknown() throws {
        try pm.createProfile(name: "a")
        try pm.createProfile(name: "b")
        #expect(throws: ProfileError.profileExists("b")) { try pm.renameProfile("a", to: "b") }
        #expect(throws: ProfileError.profileNotFound("ghost")) { try pm.renameProfile("ghost", to: "x") }
        #expect(try pm.renameProfile("a", to: "a") == "a") // no-op
    }

    @Test func testDeleteProfileRefusesActiveDeletesInactive() throws {
        try pm.migrate(name: "main")
        try pm.createProfile(name: "gone")

        #expect(throws: ProfileError.profileIsActive("main")) { try pm.deleteProfile(name: "main") }
        try pm.deleteProfile(name: "gone")
        #expect(pm.profiles() == ["main"])
        #expect(throws: ProfileError.profileNotFound("gone")) { try pm.deleteProfile(name: "gone") }
    }

    @Test func testDeleteProfileKeepsSharedHistory() throws {
        try seedTwoProfiles()
        try pm.enableSharedHistory()
        try pm.migrate(name: "main") // makes "main" active so a/b are deletable

        try pm.deleteProfile(name: "b")
        // b's sessions were merged into the shared master before; still there.
        let master = pm.sharedDir.appendingPathComponent("\(ProfileManager.sessionTrees[0])/acct1/org1")
        #expect(fm.fileExists(atPath: master.appendingPathComponent("local_3.json").path),
                "deleting a profile must not touch shared history")
    }

    // MARK: - Shared history

    /// a: acct1/org1 with 2 files (master), b: acct2/org2 with 1 file + an agent tree.
    func seedTwoProfiles() throws {
        let code = ProfileManager.sessionTrees[0], agent = ProfileManager.sessionTrees[1]
        try write("a1", to: profile("a").appendingPathComponent("\(code)/acct1/org1/local_1.json"))
        try write("a2", to: profile("a").appendingPathComponent("\(code)/acct1/org1/local_2.json"))
        try write("b1", to: profile("b").appendingPathComponent("\(code)/acct2/org2/local_3.json"))
        try write("bx", to: profile("b").appendingPathComponent("\(agent)/acct2/org2/agent.json"))
    }

    @Test func testEnableSharedHistoryMergesLinksAndBacksUp() throws {
        try seedTwoProfiles()
        let code = ProfileManager.sessionTrees[0], agent = ProfileManager.sessionTrees[1]

        let backup = try pm.enableSharedHistory()

        // Backup exists and holds the originals.
        let backupDir = try #require(backup)
        #expect(backupDir.lastPathComponent.hasPrefix("claude-session-backup-"))
        #expect(try String(contentsOf: backupDir.appendingPathComponent("b/\(code)/acct2/org2/local_3.json"), encoding: .utf8)
            == "b1")

        // Every profile tree is now a symlink into _shared-sessions (missing ones included).
        for profileName in ["a", "b"] {
            for tree in ProfileManager.sessionTrees {
                let link = profile(profileName).appendingPathComponent(tree)
                #expect(isSymlink(link), "\(profileName)/\(tree) should be a symlink")
                #expect(try fm.destinationOfSymbolicLink(atPath: link.path)
                    == pm.sharedDir.appendingPathComponent(tree).path)
            }
        }

        // Master org dir (acct1/org1, most files) got acct2/org2's file merged in;
        // acct2/org2 is now a symlink to the master.
        let sharedCode = pm.sharedDir.appendingPathComponent(code)
        let master = sharedCode.appendingPathComponent("acct1/org1")
        #expect(isRealDir(master))
        for f in ["local_1.json", "local_2.json", "local_3.json"] {
            #expect(fm.fileExists(atPath: master.appendingPathComponent(f).path), "\(f) missing in master")
        }
        let other = sharedCode.appendingPathComponent("acct2/org2")
        #expect(isSymlink(other))
        #expect(try fm.destinationOfSymbolicLink(atPath: other.path) == master.path)

        // All sessions visible through profile b's path (symlink chain).
        #expect(fm.fileExists(
            atPath: profile("b").appendingPathComponent("\(code)/acct2/org2/local_1.json").path
        ))

        // Single org dir in the agent tree: merged, no account-level linking needed.
        #expect(try String(contentsOf: pm.sharedDir.appendingPathComponent("\(agent)/acct2/org2/agent.json"), encoding: .utf8)
            == "bx")
        #expect(pm.sharedHistoryEnabled)
    }

    @Test func testEnableSharedHistoryNeverOverwrites() throws {
        let code = ProfileManager.sessionTrees[0]
        try write("A-version", to: profile("a").appendingPathComponent("\(code)/acct/org/same.json"))
        try write("B-version", to: profile("b").appendingPathComponent("\(code)/acct/org/same.json"))

        let backup = try #require(try pm.enableSharedHistory())

        // First merge (a, alphabetical) wins; b's copy never overwrites — but survives in backup.
        #expect(try String(contentsOf: pm.sharedDir.appendingPathComponent("\(code)/acct/org/same.json"), encoding: .utf8)
            == "A-version")
        #expect(try String(contentsOf: backup.appendingPathComponent("b/\(code)/acct/org/same.json"), encoding: .utf8)
            == "B-version")
    }

    @Test func testHasAccountIDsRequiresBothLoginFiles() throws {
        let org = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        try write("x", to: profile("p").appendingPathComponent("placeholder"))
        #expect(!pm.hasAccountIDs(profile: "p"))
        try write(#"{"ownerAccountId":"acct"}"#, to: profile("p").appendingPathComponent("cowork-enabled-cli-ops.json"))
        #expect(!pm.hasAccountIDs(profile: "p"), "needs org ids too")
        try write(#"{"dxt:desk:\#(org)":1}"#, to: profile("p").appendingPathComponent("config.json"))
        #expect(pm.hasAccountIDs(profile: "p"))
    }

    @Test func testDisableSharedHistoryGivesEachProfileACopy() throws {
        let code = ProfileManager.sessionTrees[0]
        let orgA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let orgB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        try write("a1", to: profile("a").appendingPathComponent("\(code)/acctA/\(orgA)/one.json"))
        try write("a2", to: profile("a").appendingPathComponent("\(code)/acctA/\(orgA)/two.json"))
        try write("b1", to: profile("b").appendingPathComponent("\(code)/acctB/\(orgB)/three.json"))
        try write(#"{"ownerAccountId":"acctA"}"#, to: profile("a").appendingPathComponent("cowork-enabled-cli-ops.json"))
        try write(#"{"ownerAccountId":"acctB"}"#, to: profile("b").appendingPathComponent("cowork-enabled-cli-ops.json"))
        try write(#"{"dxt:desk:\#(orgA)":1}"#, to: profile("a").appendingPathComponent("config.json"))
        try write(#"{"dxt:desk:\#(orgB)":1}"#, to: profile("b").appendingPathComponent("config.json"))

        try pm.enableSharedHistory()
        try pm.disableSharedHistory()

        #expect(!pm.sharedHistoryEnabled)
        #expect(!fm.fileExists(atPath: pm.sharedDir.path), "shared dir must be removed")
        // Both profiles own real trees again — with the full combined copy
        // under their own account/org ids, not links into the removed dir.
        for (p, acct, org) in [("a", "acctA", orgA), ("b", "acctB", orgB)] {
            let tree = profile(p).appendingPathComponent(code)
            #expect(isRealDir(tree), "\(p)'s tree should be a real directory")
            let orgDir = tree.appendingPathComponent("\(acct)/\(org)")
            #expect(!isSymlink(orgDir))
            for f in ["one.json", "two.json", "three.json"] {
                #expect(fm.fileExists(atPath: orgDir.appendingPathComponent(f).path),
                        "\(p) should keep \(f)")
            }
        }
    }

    @Test func testRerunLinksAccountThatLoggedInAfterEnable() throws {
        try seedTwoProfiles()
        try pm.enableSharedHistory()

        // A new account logs in on a fresh profile: Claude writes its org dir
        // through the profile symlink, i.e. straight into the shared tree.
        let code = ProfileManager.sessionTrees[0]
        try write("n1", to: pm.sharedDir.appendingPathComponent("\(code)/acct3/org3/local_9.json"))

        try pm.enableSharedHistory() // re-run on next profile switch

        let master = pm.sharedDir.appendingPathComponent("\(code)/acct1/org1")
        let newcomer = pm.sharedDir.appendingPathComponent("\(code)/acct3/org3")
        #expect(isSymlink(newcomer), "new account's org dir should be linked to master")
        #expect(try fm.destinationOfSymbolicLink(atPath: newcomer.path) == master.path)
        #expect(fm.fileExists(atPath: master.appendingPathComponent("local_9.json").path))
    }

    /// An account that logged in but never opened a Code/agent session has no
    /// <account>/<org> dir — its sidebar would stay empty forever. The uuids Claude
    /// writes on login (cowork-enabled-cli-ops.json + config.json dxt keys) let the
    /// merge pre-link the org dir to the master.
    @Test func testPrelinksAccountThatNeverOpenedASession() throws {
        try seedTwoProfiles()
        try pm.enableSharedHistory()
        try pm.createProfile(name: "fresh")

        // Login writes both ids into the profile — but no session dirs at all.
        try write(#"{"ownerAccountId":"acct-fresh"}"#,
                  to: profile("fresh").appendingPathComponent("cowork-enabled-cli-ops.json"))
        try write(#"{"dxt:allowlistEnabled:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": false}"#,
                  to: profile("fresh").appendingPathComponent("config.json"))

        try pm.enableSharedHistory() // next relink (switch / Claude quit / app launch)

        let code = ProfileManager.sessionTrees[0]
        let master = pm.sharedDir.appendingPathComponent("\(code)/acct1/org1")
        let org = pm.sharedDir
            .appendingPathComponent("\(code)/acct-fresh/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(isSymlink(org), "org dir must be pre-linked to the master")
        #expect(try fm.destinationOfSymbolicLink(atPath: org.path) == master.path)
        // Combined list readable through the fresh profile's own path.
        #expect(fm.fileExists(atPath: profile("fresh")
            .appendingPathComponent("\(code)/acct-fresh/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/local_1.json").path))

        // Idempotent: re-run leaves the link alone.
        try pm.enableSharedHistory()
        #expect(isSymlink(org))
    }

    /// Claude Desktop stays resident in the background, so the quit-time merge may
    /// never get a window. prelinkKnownAccounts is the symlink-only subset that is
    /// safe to run while Claude is alive.
    @Test func testPrelinkKnownAccountsStandalone() throws {
        try seedTwoProfiles()
        try pm.enableSharedHistory()
        try pm.createProfile(name: "fresh")
        try write(#"{"ownerAccountId":"acct-live"}"#,
                  to: profile("fresh").appendingPathComponent("cowork-enabled-cli-ops.json"))
        try write(#"{"dxt:allowlistEnabled:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": false}"#,
                  to: profile("fresh").appendingPathComponent("config.json"))

        try pm.prelinkKnownAccounts() // no merge — as if Claude were still running

        let code = ProfileManager.sessionTrees[0]
        let org = pm.sharedDir
            .appendingPathComponent("\(code)/acct-live/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(isSymlink(org))
        #expect(try fm.destinationOfSymbolicLink(atPath: org.path)
            == pm.sharedDir.appendingPathComponent("\(code)/acct1/org1").path)

        // A pending merge (two real org dirs) makes the master ambiguous — no-op then.
        try write("x", to: pm.sharedDir.appendingPathComponent("\(code)/acct-other/org-other/local_z.json"))
        try write(#"{"ownerAccountId":"acct-late"}"#,
                  to: profile("fresh").appendingPathComponent("cowork-enabled-cli-ops.json"))
        try pm.prelinkKnownAccounts()
        #expect(!fm.fileExists(atPath: pm.sharedDir.appendingPathComponent("\(code)/acct-late").path),
                "must not pick a master while a merge is pending")
    }

    @Test func testEnableSharedHistoryIsIdempotent() throws {
        try seedTwoProfiles()
        #expect(try pm.enableSharedHistory() != nil)

        let secondBackup = try pm.enableSharedHistory(now: Date().addingTimeInterval(60))
        #expect(secondBackup == nil, "re-run must be a no-op")

        let backups = try fm.contentsOfDirectory(atPath: home.path)
            .filter { $0.hasPrefix("claude-session-backup-") }
        #expect(backups.count == 1)

        // Structure intact after re-run.
        let master = pm.sharedDir.appendingPathComponent("\(ProfileManager.sessionTrees[0])/acct1/org1")
        #expect(isRealDir(master))
        #expect(try fm.contentsOfDirectory(atPath: master.path).sorted()
            == ["local_1.json", "local_2.json", "local_3.json"])
    }

    // MARK: - Restore from backup

    @Test func testRestoreSeparatesPerAccount() throws {
        try seedTwoProfiles()
        let code = ProfileManager.sessionTrees[0], agent = ProfileManager.sessionTrees[1]
        let backup = try #require(try pm.enableSharedHistory())

        // A session created while sharing was on lands in the shared master, via a's symlink.
        try write("post", to: profile("a").appendingPathComponent("\(code)/acct1/org1/post_enable.json"))

        try pm.restoreFromBackup(backup)

        // Sharing is off; the pile is archived (not deleted) with the post-enable session inside.
        #expect(!pm.sharedHistoryEnabled)
        #expect(!fm.fileExists(atPath: pm.sharedDir.path))
        let archive = try #require(try fm.contentsOfDirectory(atPath: home.path)
            .first { $0.hasPrefix("claude-shared-archive-") })
        #expect(fm.fileExists(atPath: home.appendingPathComponent(archive)
            .appendingPathComponent("\(code)/acct1/org1/post_enable.json").path))

        // Each profile is a real tree with EXACTLY its own pre-enable sessions — no cross-mixing.
        let aTree = profile("a").appendingPathComponent(code)
        #expect(isRealDir(aTree))
        #expect(try fm.contentsOfDirectory(atPath: aTree.appendingPathComponent("acct1/org1").path).sorted()
            == ["local_1.json", "local_2.json"])
        #expect(!fm.fileExists(atPath: aTree.appendingPathComponent("acct2").path),
                "a must not gain b's account")
        #expect(!fm.fileExists(atPath: aTree.appendingPathComponent("acct1/org1/post_enable.json").path),
                "post-enable session is archived, not restored")

        let bCode = profile("b").appendingPathComponent(code)
        #expect(isRealDir(bCode))
        #expect(try fm.contentsOfDirectory(atPath: bCode.appendingPathComponent("acct2/org2").path).sorted()
            == ["local_3.json"])
        #expect(fm.fileExists(atPath: profile("b")
            .appendingPathComponent("\(agent)/acct2/org2/agent.json").path))
    }

    @Test func testRestoreGivesEmptyTreeToProfileNotInBackup() throws {
        try seedTwoProfiles()
        let backup = try #require(try pm.enableSharedHistory())
        try pm.createProfile(name: "c") // created after enable → symlinked, absent from backup

        try pm.restoreFromBackup(backup)

        for tree in ProfileManager.sessionTrees {
            let cTree = profile("c").appendingPathComponent(tree)
            #expect(isRealDir(cTree), "c's \(tree) should be a real dir")
            #expect(try fm.contentsOfDirectory(atPath: cTree.path) == [], "and empty")
        }
    }

    @Test func testRestoreRejectsInvalidBackup() throws {
        try seedTwoProfiles()
        try pm.enableSharedHistory()
        let bogus = home.appendingPathComponent("not-a-backup")
        try write("junk", to: bogus.appendingPathComponent("readme.txt"))

        #expect(throws: ProfileError.invalidBackup("not-a-backup")) { try pm.restoreFromBackup(bogus) }
        // Nothing touched: sharing still on, profiles still symlinked.
        #expect(pm.sharedHistoryEnabled)
        #expect(isSymlink(profile("a").appendingPathComponent(ProfileManager.sessionTrees[0])))
    }

    @Test func testRestoreBacksUpCurrentRealTreesFirst() throws {
        // One profile with login ids so disable leaves it a real tree to protect.
        let code = ProfileManager.sessionTrees[0]
        let orgA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        try write("a1", to: profile("a").appendingPathComponent("\(code)/acctA/\(orgA)/one.json"))
        try write(#"{"ownerAccountId":"acctA"}"#, to: profile("a").appendingPathComponent("cowork-enabled-cli-ops.json"))
        try write(#"{"dxt:desk:\#(orgA)":1}"#, to: profile("a").appendingPathComponent("config.json"))

        let backup = try #require(try pm.enableSharedHistory())
        try pm.disableSharedHistory()                 // a's tree is a real dir again
        #expect(isRealDir(profile("a").appendingPathComponent(code)))

        // A session created after disable — only in the live tree, not in the enable-time backup.
        try write("after", to: profile("a").appendingPathComponent("\(code)/acctA/\(orgA)/after_disable.json"))

        try pm.restoreFromBackup(backup)

        // The prerestore backup captured the live tree (incl. after_disable) → restore is reversible.
        let prerestore = try #require(try fm.contentsOfDirectory(atPath: home.path)
            .first { $0.hasPrefix("claude-session-prerestore-") })
        #expect(fm.fileExists(atPath: home.appendingPathComponent(prerestore)
            .appendingPathComponent("a/\(code)/acctA/\(orgA)/after_disable.json").path))

        // And a is back to exactly the enable-time backup (after_disable gone from the live tree).
        let aOrg = profile("a").appendingPathComponent("\(code)/acctA/\(orgA)")
        #expect(try fm.contentsOfDirectory(atPath: aOrg.path).sorted() == ["one.json"])
    }

    // MARK: - Switch + shared-history visibility

    struct Acct { let profile: String; let acct: String; let org: String }

    func login(_ a: Acct) throws {
        try write(#"{"ownerAccountId":"\#(a.acct)"}"#,
                  to: profile(a.profile).appendingPathComponent("cowork-enabled-cli-ops.json"))
        try write(#"{"dxt:desk:\#(a.org)":1}"#,
                  to: profile(a.profile).appendingPathComponent("config.json"))
    }

    /// Simulate Claude (active account `a`) creating a session: writes through the
    /// live Claude symlink exactly as the app does — claudeDir -> profile -> shared tree.
    func claudeWrite(_ uuid: String, as a: Acct) throws {
        let p = pm.claudeDir.appendingPathComponent(
            "\(ProfileManager.sessionTrees[0])/\(a.acct)/\(a.org)/\(uuid)")
        try write("session", to: p)
    }

    /// Mirror the switch flow: switch first, then relink promoting the now-active
    /// account to master (as AppState.switchTo does after the fix).
    func appSwitch(to a: Acct) throws {
        if !pm.profiles().contains(a.profile) { try pm.createProfile(name: a.profile) }
        try pm.switchTo(name: a.profile)
        if pm.sharedHistoryEnabled { try pm.enableSharedHistory(promoteActive: true) }
    }

    func activeOrg(_ a: Acct) -> URL {
        pm.claudeDir.appendingPathComponent("\(ProfileManager.sessionTrees[0])/\(a.acct)/\(a.org)")
    }

    /// Sessions the active account's sidebar can actually see (its org path, symlinks resolved).
    func visibleSessions(_ a: Acct) -> Set<String> {
        let items = (try? fm.contentsOfDirectory(atPath: activeOrg(a).resolvingSymlinksInPath().path)) ?? []
        return Set(items)
    }

    /// Switching to any profile must hand it the real master pile — never a symlink
    /// Claude's own writes could shadow (the "session hilang after switch" bug) — and
    /// every shared session stays visible through it.
    @Test func testSwitchGivesActiveProfileTheRealMasterAndKeepsSessionsVisible() throws {
        let main = Acct(profile: "main", acct: "acct-main", org: "11111111-1111-1111-1111-111111111111")
        let work = Acct(profile: "work", acct: "acct-work", org: "22222222-2222-2222-2222-222222222222")
        let other = Acct(profile: "other", acct: "acct-other", org: "33333333-3333-3333-3333-333333333333")

        try makeRealClaudeDir()
        try pm.migrate(name: main.profile)          // main active
        for a in [main, work, other] {
            if a.profile != main.profile { try pm.createProfile(name: a.profile) }
            try login(a)
        }
        // Seed main heavily so the file-count master is main's org, not work/other's:
        // without master-follows-active they would run on a symlink to it.
        var all: Set<String> = []
        for i in 0..<5 { try claudeWrite("s-main-\(i)", as: main); all.insert("s-main-\(i)") }
        try pm.enableSharedHistory(promoteActive: true)

        let seq = [work, other, main, work, other, work, main, other]
        for (i, next) in seq.enumerated() {
            try appSwitch(to: next)
            let id = "s-\(next.profile)-\(i + 1)"
            try claudeWrite(id, as: next); all.insert(id)

            #expect(isRealDir(activeOrg(next)),
          "switch #\(i + 1): \(next.profile)'s org dir must be the real master, not a symlink")
            let visible = visibleSessions(next)
            #expect(visible == all,
         "switch #\(i + 1) to \(next.profile): missing \(all.subtracting(visible))")
        }
    }

    /// An account that logged in and opened a session before it was linked owns a
    /// real "island" of its own sessions, disconnected from the shared pile. The
    /// next promoting relink must fold the pile into it — nothing lost, all visible.
    @Test func testPromotingRelinkHealsAnIslandedAccount() throws {
        let main = Acct(profile: "main", acct: "acct-main", org: "11111111-1111-1111-1111-111111111111")
        let work = Acct(profile: "work", acct: "acct-work", org: "22222222-2222-2222-2222-222222222222")

        try makeRealClaudeDir()
        try pm.migrate(name: main.profile)
        try pm.createProfile(name: work.profile)
        try login(main); try login(work)
        try claudeWrite("m1", as: main)
        try claudeWrite("m2", as: main)
        try pm.enableSharedHistory(promoteActive: true)   // master = main's org

        // work is now active but its org dir is a fresh real island Claude wrote
        // before any relink saw it (the first-login / new-org window).
        try pm.switchTo(name: work.profile)
        let island = activeOrg(work)
        try fm.removeItem(at: island)                      // drop the prelinked symlink
        try write("w1", to: island.appendingPathComponent("w1"))

        try pm.enableSharedHistory(promoteActive: true)    // heal

        #expect(isRealDir(island), "work must own the real master after the relink")
        #expect(Set(try fm.contentsOfDirectory(atPath: island.path))
            == ["m1", "m2", "w1"], "island folded into the shared pile, nothing lost")
    }

    // MARK: - Display order

    @Test func testOrderedRespectsSavedOrderAndPutsUnknownNamesLast() throws {
        try pm.saveOrder(["charlie", "alpha"])
        // charlie/alpha follow the saved order; bravo/delta are unknown, so they
        // sort to the end alphabetically. round-trips through the file on disk.
        #expect(pm.savedOrder() == ["charlie", "alpha"])
        #expect(pm.ordered(["alpha", "bravo", "charlie", "delta"]) == ["charlie", "alpha", "bravo", "delta"])
        // No file yet on a fresh manager → pure alphabetical.
        let fresh = ProfileManager(home: fm.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(fresh.ordered(["b", "a"]) == ["a", "b"])
    }
}
