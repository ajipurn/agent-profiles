import Foundation
import ClaudeProfilesCore
import CodexProfilesCore
import UsageCostCore

struct Commands {
    let context: CLI.Context
    let json: Bool

    var claude: ProfileManager { ProfileManager(home: context.home) }
    var claudeCode: CLIProfileManager { CLIProfileManager(home: context.home) }
    var codex: AccountSwitcher { AccountSwitcher(paths: context.codexPaths, clients: NullCodexClients()) }

    // MARK: - status

    func status() throws {
        let now = Date()
        let desktop = claude.activeProfile()
        let usage = desktop.flatMap(claude.usage(profile:)).map { ClaudeUsageReport($0, now: now) }
        let code = claudeCode.activeProfile()
        let account = codexAccount()

        if json {
            return emit([
                "claude": ["profile": orNull(desktop), "usage": orNull(usage?.json)] as [String: Any],
                // null is the default account, the plain ~/.claude
                "claudeCode": ["profile": orNull(code)] as [String: Any],
                "codex": ["signedIn": account.signedIn, "account": orNull(account.report?.json)] as [String: Any],
            ] as [String: Any])
        }
        var claudeLine = desktop ?? (claude.profiles().isEmpty ? "not set up" : "no active profile")
        if let usage { claudeLine += ": " + usage.text(now: now) }
        context.output([
            row(.claude, claudeLine),
            row(.claudeCLI, code ?? "default"),
            row(.codex, account.text),
        ].joined(separator: "\n"))
    }

    /// The live Codex login, by the saved account it matches.
    func codexAccount() -> (signedIn: Bool, report: CodexAccountReport?, text: String) {
        guard let live = try? codex.liveState(), let file = live.file else { return (false, nil, "signed out") }
        let profiles = (try? codex.profiles()) ?? []
        if let profile = profiles.first(where: { $0.id == live.matchingProfileID }) {
            let report = CodexAccountReport(profile, active: true)
            return (true, report, report.name)
        }
        return (true, nil, "signed in as \(file.identity?.email ?? "an unsaved account") (not saved)")
    }

    // MARK: - list

    func list(_ only: Provider?) throws {
        let providers = only.map { [$0] } ?? Provider.allCases
        var objects: [String: Any] = [:]
        var sections: [String] = []
        for provider in providers {
            let entries: [ListEntry]
            switch provider {
            case .claude:
                let active = claude.activeProfile()
                entries = claude.ordered(claude.profiles()).map { ListEntry(name: $0, active: $0 == active) }
            case .claudeCLI:
                let active = claudeCode.activeProfile()
                // Default, the plain ~/.claude, is null in JSON.
                entries = [ListEntry(name: "default", active: active == nil, json: ["name": NSNull(), "active": active == nil])]
                    + claudeCodeNames().map { ListEntry(name: $0, active: $0 == active) }
            case .codex:
                let activeID = (try? codex.liveState())?.matchingProfileID
                entries = try codexProfiles().map {
                    let report = CodexAccountReport($0, active: $0.id == activeID)
                    return ListEntry(name: report.name, active: report.active, json: report.json)
                }
            }
            objects[provider.jsonKey] = entries.map { $0.json }
            let lines = entries.map { ($0.active ? "* " : "  ") + $0.name }
            sections.append(section(only == nil ? provider.title : nil, lines))
        }
        if json { return emit(only.map { objects[$0.jsonKey]! } ?? objects) }
        context.output(sections.joined(separator: "\n"))
    }

    /// Every name Claude Code can switch to: its own profiles and the Desktop
    /// ones, whose config folder the app makes on first use.
    func claudeCodeNames() -> [String] {
        claude.ordered(Array(Set(claudeCode.profiles()).union(claude.profiles())))
    }

    /// Favorites first, then in the order picked in Settings: the hotkey order.
    func codexProfiles() throws -> [Profile] {
        ProfileList.arranged(try codex.profiles(), query: "", favoritesOnly: false,
                             settings: codex.store.loadSettings(), activeID: nil, usage: [:])
    }

    // MARK: - usage

    func usage(_ only: Provider?) async throws {
        guard only != .claudeCLI else {
            throw CLIError.usage("Claude Code shares its account's usage with Claude Desktop; use usage claude")
        }
        let now = Date()
        var objects: [String: Any] = [:]
        var sections: [String] = []
        if only != .codex {
            let reports = claude.ordered(claude.profiles()).map { name in
                (name, claude.usage(profile: name).map { ClaudeUsageReport($0, now: now) })
            }
            objects[Provider.claude.jsonKey] = reports.map { ["name": $0.0, "usage": orNull($0.1?.json)] as [String: Any] }
            let width = reports.map { $0.0.count }.max() ?? 0
            let lines = reports.map { name, usage in
                name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + (usage?.text(now: now) ?? "no usage seen yet")
            }
            sections.append(section(only == nil ? Provider.claude.title : nil, lines))
        }
        if only != .claude {
            let report = try await codexUsage()
            objects[Provider.codex.jsonKey] = report.json
            sections.append(section(only == nil ? Provider.codex.title : nil, [report.text(now: now)]))
        }
        if json { return emit(only.map { objects[$0.jsonKey]! } ?? objects) }
        context.output(sections.joined(separator: "\n"))
    }

    /// Fetched now, the way the app does it: a token refreshed on the way is
    /// saved back unless another switch or login replaced the login meanwhile.
    func codexUsage() async throws -> CodexUsageReport {
        let switcher = codex
        let live = try switcher.liveState()
        guard let file = live.file else { throw CLIError.failed("Codex is signed out") }
        guard file.isChatGPTSession else {
            throw CLIError.failed("Codex is signed in with an API key, which has no usage limits to show")
        }
        let result: UsageFetchResult
        do {
            result = try await context.fetchCodexUsage(file)
        } catch {
            throw CLIError.failed("Codex usage could not be loaded: \(error.localizedDescription)")
        }
        if let updated = result.updatedSnapshot {
            _ = try switcher.applyUsageRefresh(updated, replacing: file, profileID: live.matchingProfileID)
        }
        let profile = try switcher.profiles().first { $0.id == live.matchingProfileID }
        return CodexUsageReport(
            account: profile.map { CodexAccountReport($0, active: true) },
            fallbackName: file.identity?.email ?? "unsaved account",
            usage: result.usage
        )
    }

    // MARK: - cost

    func cost() async {
        let summary = await CostScanner(sources: .standard(home: context.home)).scan()
        let providers = CostProvider.allCases
        if json {
            var object: [String: Any] = ["unpricedModels": summary.unpricedModels.sorted()]
            for period in CostPeriod.allCases {
                var amounts: [String: Any] = ["total": costJSON(summary.total(period))]
                for provider in providers { amounts[provider.rawValue] = costJSON(summary.amount(period, provider)) }
                object[period.rawValue] = amounts
            }
            return emit(object)
        }
        func cell(_ text: String) -> String { String(repeating: " ", count: max(0, 11 - text.count)) + text }
        var lines = [String(repeating: " ", count: 10) + (providers.map { cell(Provider.costTitle($0)) } + [cell("Total")]).joined()]
        for period in CostPeriod.allCases {
            let amounts = providers.map { summary.amount(period, $0) } + [summary.total(period)]
            lines.append(period.title.padding(toLength: 10, withPad: " ", startingAt: 0)
                + amounts.map { cell(Self.dollars($0.dollars)) }.joined())
        }
        if !summary.unpricedModels.isEmpty {
            lines.append("Not priced: " + summary.unpricedModels.sorted().joined(separator: ", "))
        }
        lines.append("API list prices for what the local logs show; on a subscription, not a bill.")
        context.output(lines.joined(separator: "\n"))
    }

    func costJSON(_ amount: CostAmount) -> [String: Any] { ["dollars": amount.dollars, "tokens": amount.tokens] }

    static func dollars(_ value: Double) -> String { String(format: "$%.2f", value) }

    // MARK: - output

    /// A titled block when several providers are shown; lines alone for one.
    func section(_ title: String?, _ lines: [String]) -> String {
        ((title.map { [$0] } ?? []) + (lines.isEmpty ? ["  (none)"] : lines)).joined(separator: "\n")
    }

    func row(_ provider: Provider, _ text: String) -> String {
        provider.title.padding(toLength: 16, withPad: " ", startingAt: 0) + text
    }

    func emit(_ object: Any) {
        // An object JSON can't hold would raise, not throw; dates are strings by now.
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return context.errorOutput("agent-profiles: could not write JSON") }
        context.output(String(decoding: data, as: UTF8.self))
    }
}

struct ListEntry {
    var name: String
    var active: Bool
    var json: [String: Any]

    init(name: String, active: Bool, json: [String: Any]? = nil) {
        self.name = name
        self.active = active
        self.json = json ?? ["name": name, "active": active]
    }
}

/// JSON has no nil; a missing value is an explicit null.
func orNull(_ value: Any?) -> Any { value ?? NSNull() }

extension Provider {
    var jsonKey: String {
        switch self {
        case .claude: "claude"
        case .claudeCLI: "claudeCode"
        case .codex: "codex"
        }
    }

    static func costTitle(_ provider: CostProvider) -> String {
        switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}
