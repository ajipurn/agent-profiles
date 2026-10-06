import Foundation
import Testing
@testable import AgentCLI
import ClaudeProfilesCore
import CodexProfilesCore
import PlatformSupport
import UsageHistoryCore

/// Every test gets its own home: Claude Desktop profiles "personal" and
/// "work" (active), and two saved Codex accounts with me@example.com live.
final class AgentCLITests {
    let fm = FileManager.default
    var home: URL!
    var paths: CodexPaths!

    init() throws {
        home = fm.temporaryDirectory.appendingPathComponent("agent-cli-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        paths = CodexPaths(codexHome: home.appendingPathComponent(".codex"),
                           storeRoot: home.appendingPathComponent("CodexProfiles"))
    }

    deinit {
        try? fm.removeItem(at: home)
    }

    func setUpClaude() throws {
        let manager = ProfileManager(home: home)
        try manager.migrate(name: "work")
        try manager.createProfile(name: "personal")
    }

    func setUpCodex() throws {
        let switcher = AccountSwitcher(paths: paths, clients: NullCodexClients())
        let me = try Fixtures.snapshot(email: "me@example.com", accountID: "acc-me")
        _ = try switcher.store.save(name: "me@example.com", snapshot: me)
        _ = try switcher.store.save(name: "team@example.com",
                                    snapshot: try Fixtures.snapshot(email: "team@example.com", accountID: "acc-team"))
        try switcher.writeLiveSnapshot(me)
    }

    func run(
        _ arguments: [String],
        openInApp: (@Sendable (URL) throws -> Void)? = nil,
        fetch: @escaping @Sendable (AuthSnapshot) async throws -> UsageFetchResult = { _ in throw Fixtures.Offline() },
        timeout: TimeInterval = 5
    ) async -> (code: Int32, out: String, err: String) {
        let out = LockedValue<[String]>([]), err = LockedValue<[String]>([])
        var context = CLI.Context(
            home: home, codexPaths: paths, openInApp: openInApp, fetchCodexUsage: fetch,
            output: { text in out.withLock { $0.append(text) } },
            errorOutput: { text in err.withLock { $0.append(text) } }
        )
        context.switchTimeout = timeout
        context.pollInterval = 0.01
        let code = await CLI.run(arguments, context: context)
        return (code, out.withLock { $0.joined(separator: "\n") }, err.withLock { $0.joined(separator: "\n") })
    }

    func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Parsed JSON numbers and booleans arrive as NSNumber on some platforms.
    func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue ?? (value as? Double) }
    func flag(_ value: Any?) -> Bool? { (value as? Bool) ?? (value as? NSNumber)?.boolValue }

    // MARK: - Reading

    @Test func statusShowsOneLinePerProvider() async throws {
        try setUpClaude()
        let result = await run([])
        #expect(result.code == 0)
        #expect(result.out == """
            Claude Desktop  work
            Claude Code     default
            Codex           signed out
            """)
    }

    @Test func statusAsJSON() async throws {
        try setUpClaude()
        try setUpCodex()
        let result = await run(["status", "--json"])
        #expect(result.code == 0)
        let status = try object(result.out)
        let claude = status["claude"] as? [String: Any]
        #expect(claude?["profile"] as? String == "work")
        #expect(claude?["usage"] is NSNull) // Claude Desktop never fetched usage here
        #expect((status["claudeCode"] as? [String: Any])?["profile"] is NSNull) // the plain ~/.claude
        let codex = status["codex"] as? [String: Any]
        #expect(flag(codex?["signedIn"]) == true)
        #expect((codex?["account"] as? [String: Any])?["email"] as? String == "me@example.com")
    }

    @Test func listMarksTheActiveOnes() async throws {
        try setUpClaude()
        try setUpCodex()
        #expect(await run(["list", "claude"]).out == "  personal\n* work")
        // Claude Code can switch to every Desktop name too; Default comes first.
        #expect(await run(["list", "claude-cli"]).out == "* default\n  personal\n  work")
        #expect(await run(["list", "codex"]).out == "* me@example.com\n  team@example.com")

        let all = try object(await run(["list", "--json"]).out)
        let accounts = try #require(all["codex"] as? [[String: Any]])
        #expect(accounts.map { flag($0["active"]) } == [true, false])
        #expect((all["claude"] as? [[String: Any]])?.count == 2)
    }

    @Test func codexUsageIsFetchedAndARefreshedLoginKept() async throws {
        try setUpCodex()
        let live = try #require(try AccountSwitcher(paths: paths, clients: NullCodexClients()).liveState().file)
        let refreshed = try live.applyingTokenRefresh(accessToken: "access-new", refreshToken: nil, idToken: nil)
        let usage = CodexUsage(planType: "plus",
                               primary: UsageWindow(usedPercent: 12, resetAt: Date().addingTimeInterval(3 * 3600)),
                               secondary: UsageWindow(usedPercent: 30))
        let result = await run(["usage", "codex", "--json"], fetch: { _ in
            UsageFetchResult(usage: usage, updatedSnapshot: refreshed)
        })
        #expect(result.code == 0)
        let report = try object(result.out)
        #expect(report["plan"] as? String == "plus")
        #expect(number((report["session"] as? [String: Any])?["usedPercent"]) == 12)
        #expect(number((report["weekly"] as? [String: Any])?["usedPercent"]) == 30)
        // The token refreshed on the way replaced the live login.
        let saved = try AccountSwitcher(paths: paths, clients: NullCodexClients()).liveState().file
        #expect(saved?.accessToken == "access-new")
    }

    @Test func codexUsageWhenSignedOutFails() async throws {
        let result = await run(["usage", "codex"])
        #expect(result.code == 1)
        #expect(result.err.contains("signed out"))
    }

    @Test func costWithoutLogsIsZero() async throws {
        let result = await run(["cost", "--json"])
        #expect(result.code == 0)
        let cost = try object(result.out)
        let total = (cost["today"] as? [String: Any])?["total"] as? [String: Any]
        #expect(number(total?["dollars"]) == 0)
        #expect(cost["yesterday"] != nil && cost["last30Days"] != nil)
    }

    // MARK: - History

    /// Readings as the app would have kept them, `hours` before now.
    func record(_ readings: [(provider: UsageSample.Provider, account: String, hours: Double,
                              session: Double?, weekly: Double?)]) async throws {
        let now = Date()
        try await UsageHistory(home: home).replace(with: readings.map {
            UsageSample(provider: $0.provider, account: $0.account, at: now.addingTimeInterval(-$0.hours * 3600),
                        session: $0.session, weekly: $0.weekly)
        })
    }

    @Test func historySummarizesEachAccountInTheAppsOrder() async throws {
        try setUpClaude()
        try await record([
            (.claude, "work", 72, 40, 20),
            (.claude, "work", 48, 100, 50),
            (.claude, "work", 47.5, 100, 55), // still full: counted once
            (.claude, "work", 24, 30, 60),
            (.claude, "work", 240, 100, 90), // ten days ago: outside the default week
            (.claude, "old", 30, 10, 5), // a profile since removed
        ])
        let result = await run(["history", "claude"])
        #expect(result.code == 0)
        #expect(result.out == """
            Account        Weekly peak  Weekly full  Session peak  Session full  Last reading
            personal       no readings
            work                   60%            –          100%            1×  1d ago
            old (removed)           5%            –           10%             –  1d 6h ago
            """)
    }

    @Test func historyAsJSONCoversTheDaysAsked() async throws {
        try setUpCodex()
        let saved = try AccountSwitcher(paths: paths, clients: NullCodexClients()).profiles()
        let me = try #require(saved.first { $0.matches("me@example.com") }).id.uuidString
        let team = try #require(saved.first { $0.matches("team@example.com") }).id.uuidString
        let gone = UUID().uuidString
        try await record([
            (.codex, me, 240, 100, 80),
            (.codex, me, 2, 20, 85),
            (.codex, gone, 5, 50, nil),
        ])
        func accounts(_ arguments: [String]) async throws -> [[String: Any]] {
            let out = await run(arguments).out
            return try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]])
        }

        let month = try await accounts(["history", "codex", "--days", "30", "--json"])
        let goneName = "Removed account \(gone.prefix(4))"
        #expect(month.map { $0["name"] as? String } == ["me@example.com", "team@example.com", goneName])
        #expect(month.map { flag($0["removed"]) } == [false, false, true])
        #expect(month.map { $0["id"] as? String } == [me, team, gone])
        let session = month[0]["session"] as? [String: Any], weekly = month[0]["weekly"] as? [String: Any]
        #expect(number(session?["timesFull"]) == 1)
        #expect(number(session?["latest"]) == 20)
        #expect(number(weekly?["peak"]) == 85)
        #expect((month[0]["readings"] as? [[String: Any]])?.count == 2)
        #expect((month[1]["readings"] as? [[String: Any]])?.isEmpty == true)
        #expect(month[1]["lastReading"] is NSNull)
        #expect(number((month[2]["weekly"] as? [String: Any])?["peak"]) == nil) // never reported

        // The default week leaves the ten-day-old full session out.
        let week = try await accounts(["history", "codex", "--days=7", "--json"])
        #expect(number((week[0]["session"] as? [String: Any])?["timesFull"]) == 0)
    }

    @Test func historyWithoutReadingsSaysHowTheyCome() async throws {
        try setUpClaude()
        let result = await run(["history"])
        #expect(result.code == 0)
        #expect(result.out.hasPrefix("Claude Desktop, last 7 days\nAccount"))
        #expect(result.out.hasSuffix("No readings yet: the Agent Profiles app keeps one every ten minutes at most while it runs."))
    }

    // MARK: - Switching

    @Test func claudeSwitchGoesThroughTheAppAndWaits() async throws {
        try setUpClaude()
        let opened = LockedValue<[URL]>([])
        let home = self.home!
        let result = await run(["switch", "claude", "personal"], openInApp: { url in
            opened.withLock { $0.append(url) }
            try ProfileManager(home: home).switchTo(name: url.lastPathComponent) // what the app does
        })
        #expect(result.code == 0)
        #expect(opened.withLock { $0 } == [URL(string: "agentprofiles://claude/personal")!])
        #expect(ProfileManager(home: home).activeProfile() == "personal")
        #expect(result.out == "Claude Desktop switched to personal.")
    }

    @Test func switchChecksTheNameBeforeAskingTheApp() async throws {
        try setUpClaude()
        let opened = LockedValue(0)
        let result = await run(["switch", "claude", "ghost"], openInApp: { _ in opened.withLock { $0 += 1 } })
        #expect(result.code == 1)
        #expect(result.err.contains("choose from personal, work"))
        #expect(opened.withLock { $0 } == 0)
    }

    @Test func switchToWhatIsActiveLeavesTheAppAlone() async throws {
        try setUpClaude()
        let opened = LockedValue(0)
        let result = await run(["switch", "claude", "work"], openInApp: { _ in opened.withLock { $0 += 1 } })
        #expect(result.code == 0)
        #expect(result.out == "Claude Desktop is on work.")
        #expect(opened.withLock { $0 } == 0)
    }

    @Test func switchSaysSoWhenTheAppDoesNotFinish() async throws {
        try setUpClaude()
        let result = await run(["switch", "claude", "personal"], openInApp: { _ in }, timeout: 0.05)
        #expect(result.code == 1)
        #expect(result.err.contains("has not switched"))
        #expect(ProfileManager(home: home).activeProfile() == "work")
    }

    @Test func switchWithoutWaitingReturnsOnceAsked() async throws {
        try setUpClaude()
        let result = await run(["switch", "claude", "personal", "--no-wait", "--json"], openInApp: { _ in })
        #expect(result.code == 0)
        #expect(try object(result.out)["state"] as? String == "requested")
    }

    @Test func codexSwitchMatchesByEmailAndWaits() async throws {
        try setUpCodex()
        let paths = self.paths!
        let opened = LockedValue<[URL]>([])
        let result = await run(["switch", "codex", "TEAM@example.com"], openInApp: { url in
            opened.withLock { $0.append(url) }
            let switcher = AccountSwitcher(paths: paths, clients: NullCodexClients())
            guard let target = try switcher.profiles().first(where: { $0.matches(url.lastPathComponent) }) else {
                throw Fixtures.Offline()
            }
            try switcher.writeLiveSnapshot(try switcher.store.loadSnapshot(target.id))
        })
        #expect(result.code == 0)
        #expect(opened.withLock { $0 } == [URL(string: "agentprofiles://codex/TEAM@example.com")!])
        #expect(result.out == "Codex switched to team@example.com.")
    }

    @Test func claudeCodeSwitchesOnItsOwnWithoutTheApp() async throws {
        try setUpClaude()
        let cli = CLIProfileManager(home: home)
        #expect(await run(["switch", "claude-cli", "work"]).code == 0)
        #expect(cli.activeProfile() == "work") // its config folder made on first use
        #expect(await run(["switch", "claude-cli", "default"]).code == 0)
        #expect(cli.activeProfile() == nil)
        // Claude Desktop has no app to ask here.
        let desktop = await run(["switch", "claude", "personal"])
        #expect(desktop.code == 1)
        #expect(desktop.err.contains("needs the Agent Profiles app"))
    }

    @Test func appURLKeepsTheNameInOnePathComponent() throws {
        #expect(try Commands.appURL(.codex, "a b/c").absoluteString == "agentprofiles://codex/a%20b%2Fc")
        #expect(try Commands.appURL(.claudeCLI, "Default").absoluteString == "agentprofiles://claude-cli/Default")
    }

    // MARK: - Command line

    @Test func badCommandLinesExitWithTwo() async {
        #expect(await run(["frobnicate"]).code == 2)
        #expect(await run(["status", "--colour"]).code == 2)
        #expect(await run(["status", "extra"]).code == 2)
        #expect(await run(["switch", "claude"]).code == 2)
        #expect(await run(["list", "gemini"]).code == 2)
        #expect(await run(["usage", "claude-cli"]).code == 2)
        #expect(await run(["history", "claude-cli"]).code == 2)
        #expect(await run(["history", "--days", "31"]).code == 2)
        #expect(await run(["history", "--days"]).code == 2)
        #expect(await run(["status", "--days", "7"]).code == 2)
        let help = await run(["--help"])
        #expect(help.code == 0)
        #expect(help.out.hasPrefix("usage: agent-profiles"))
    }
}

enum Fixtures {
    struct Offline: Error {}

    static func snapshot(email: String, accountID: String) throws -> AuthSnapshot {
        func base64URL(_ object: [String: Any]) -> String {
            (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let token = base64URL(["alg": "none", "typ": "JWT"]) + "." + base64URL([
            "email": email,
            "name": "User",
            "sub": "auth0|\(accountID)",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_user_id": accountID,
                "user_id": accountID,
                "chatgpt_plan_type": "plus",
            ],
        ]) + ".sig"
        let root: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "id_token": token,
                "access_token": "access-\(accountID)",
                "refresh_token": "refresh-\(accountID)",
                "account_id": accountID,
            ],
        ]
        return try AuthSnapshot(data: try JSONSerialization.data(withJSONObject: root))
    }
}
