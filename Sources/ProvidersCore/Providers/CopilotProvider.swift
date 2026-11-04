import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub Copilot, read with the GitHub OAuth token that Copilot's editor
/// plugins (JetBrains, Vim/Neovim, Xcode — `github-copilot/apps.json` and
/// `hosts.json`) or the Copilot CLI (`~/.copilot/config.json`, when it keeps
/// its token in plain text) leave on disk. VS Code and the CLI's Keychain
/// storage are not read: reading them prompts.
public struct CopilotProvider: UsageProvider {
    public let id = "copilot"
    public let name = "Copilot"
    public let brandHex = "#A855F7"
    public let symbol = "airplane"
    public var dashboardURL: URL? { URL(string: "https://github.com/settings/copilot") }
    public var statusPageURL: URL? { URL(string: "https://www.githubstatus.com") }

    public init() {}

    public func isSignedIn(in environment: ProviderEnvironment) -> Bool {
        Self.credential(in: environment) != nil
    }

    public func fetch(in environment: ProviderEnvironment) async throws -> ProviderSnapshot {
        guard let credential = Self.credential(in: environment) else {
            throw ProviderFetchError.notSignedIn(
                "No Copilot sign-in found. Sign in with the Copilot plugin for JetBrains, Vim/Neovim or Xcode, "
                    + "or the Copilot CLI with plain-text token storage. VS Code keeps its sign-in in the Keychain.")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.apiHost(for: credential.host)
        components.path = "/copilot_internal/user"
        guard let url = components.url else { throw ProviderFetchError.invalidResponse }
        // The GitHub OAuth token itself (`token` scheme), with the headers the
        // Copilot Chat extension sends.
        let request = ProviderHTTP.request(url, headers: [
            "Authorization": "token \(credential.token)",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
        ])
        let body = try await ProviderHTTP.object(request, in: environment)
        return try Self.snapshot(from: body, account: credential.user, fetchedAt: environment.now())
    }

    // MARK: - Mapping

    static func snapshot(from body: [String: Any], account: String?, fetchedAt: Date) throws -> ProviderSnapshot {
        if ProviderJSON.string(body["access_type_sku"])?.lowercased() == "subscription_ended" {
            throw ProviderFetchError.unsupported("Copilot subscription ended.")
        }
        let resetsAt = ProviderJSON.date(body["quota_reset_date_utc"])
            ?? ProviderJSON.date(body["quota_reset_date"])
            ?? ProviderJSON.date(body["limited_user_reset_date"])
        let windowSeconds = resetsAt.flatMap(CopilotCalendar.monthLength(endingAt:))

        var windows: [ProviderWindow] = []
        var unlimited: [String] = []
        let snapshots = body["quota_snapshots"] as? [String: Any]
        let premium = snapshots?["premium_interactions"] as? [String: Any]
        for (title, key) in [("Premium", "premium_interactions"), ("Chat", "chat"), ("Completions", "completions")] {
            switch quota(snapshots?[key]) {
            case .used(let percent):
                windows.append(ProviderWindow(title: title, usedPercent: percent, resetsAt: resetsAt, windowSeconds: windowSeconds))
            case .unlimited:
                unlimited.append(title)
            case .none:
                break
            }
        }
        // Older free-tier responses: remaining counts against monthly totals.
        if windows.isEmpty {
            let remaining = body["limited_user_quotas"] as? [String: Any]
            let totals = body["monthly_quotas"] as? [String: Any]
            for (title, key) in [("Chat", "chat"), ("Completions", "completions")] {
                guard let total = ProviderJSON.double(totals?[key]), total > 0,
                      let left = ProviderJSON.double(remaining?[key]) else { continue }
                windows.append(ProviderWindow(title: title, usedPercent: (total - left) / total * 100,
                                              resetsAt: resetsAt, windowSeconds: windowSeconds))
            }
        }

        let tokenBasedBilling = ProviderJSON.bool(body["token_based_billing"]) == true
        var details: [ProviderDetail] = []
        if ProviderJSON.bool(premium?["overage_permitted"]) == true, windows.first?.title == "Premium" {
            let overage = max(0, ProviderJSON.double(premium?["overage_count"]) ?? 0)
            details.append(ProviderDetail(title: "Overage", value: "\(CopilotFormat.number(overage)) requests"))
        }
        if let credits = ProviderJSON.double(premium?["credits_used"]), credits > 0 || tokenBasedBilling {
            details.append(ProviderDetail(title: "Credits used", value: CopilotFormat.number(credits)))
        }

        if windows.isEmpty {
            // Token-billed seats and unlimited quotas have no metered window:
            // show the plan without inventing usage.
            guard tokenBasedBilling || !unlimited.isEmpty else {
                throw ProviderFetchError.unsupported("Copilot reports no usage quota for this account.")
            }
            details += unlimited.map { ProviderDetail(title: $0, value: "Unlimited") }
        }

        return ProviderSnapshot(
            account: ProviderJSON.string(body["login"]) ?? account,
            plan: ProviderJSON.string(body["copilot_plan"]).map(CopilotFormat.titleCased),
            windows: windows,
            details: details,
            fetchedAt: fetchedAt)
    }

    private enum Quota { case used(Double), unlimited, none }

    private static func quota(_ raw: Any?) -> Quota {
        guard let snapshot = raw as? [String: Any] else { return .none }
        let entitlement = ProviderJSON.double(snapshot["entitlement"])
        let remaining = ProviderJSON.double(snapshot["remaining"])
        // The flag, or GitHub's -1 sentinel.
        if ProviderJSON.bool(snapshot["unlimited"]) == true || entitlement == -1 || remaining == -1 {
            return .unlimited
        }
        // A zero entitlement is a placeholder (token-billed seats), not 0% used.
        if entitlement == 0 { return .none }
        if let percentRemaining = ProviderJSON.double(snapshot["percent_remaining"]) {
            return .used(100 - percentRemaining)
        }
        if let entitlement, entitlement > 0, let remaining {
            return .used(100 - remaining / entitlement * 100)
        }
        return .none
    }

    // MARK: - Credentials

    struct Credential: Equatable {
        var host: String
        var token: String
        var user: String?
    }

    static func apiHost(for host: String) -> String {
        if host == "github.com" { return "api.github.com" }
        return host.hasPrefix("api.") ? host : "api.\(host)"
    }

    /// github.com first, then any other (GHE.com) host; editor plugins
    /// before the CLI.
    static func credential(in environment: ProviderEnvironment) -> Credential? {
        let candidates = editorCredentials(in: environment) + cliCredentials(in: environment)
        return candidates.first { $0.host == "github.com" } ?? candidates.first
    }

    private static func configDirectory(in environment: ProviderEnvironment) -> URL {
        if let xdg = ProviderJSON.string(environment.variables["XDG_CONFIG_HOME"]), xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        #if os(Windows)
        if let local = ProviderJSON.string(environment.variables["LOCALAPPDATA"]) {
            return URL(fileURLWithPath: local, isDirectory: true)
        }
        return environment.home.appendingPathComponent("AppData/Local", isDirectory: true)
        #else
        return environment.home.appendingPathComponent(".config", isDirectory: true)
        #endif
    }

    /// `apps.json` (`"github.com:<app id>": {user, oauth_token}`) is what the
    /// current language server writes; `hosts.json` (`"github.com": {…}`) is
    /// the older plugins' file.
    private static func editorCredentials(in environment: ProviderEnvironment) -> [Credential] {
        let directory = configDirectory(in: environment).appendingPathComponent("github-copilot", isDirectory: true)
        var found: [Credential] = []
        for file in ["apps.json", "hosts.json"] {
            guard let object = ProviderJSON.readObject(at: directory.appendingPathComponent(file)) else { continue }
            for key in object.keys.sorted() {
                guard let entry = object[key] as? [String: Any],
                      let token = cleanToken(entry["oauth_token"]),
                      let host = ProviderJSON.string(entry["host"]).flatMap(hostPart) ?? hostPart(key)
                else { continue }
                found.append(Credential(host: host, token: token, user: ProviderJSON.string(entry["user"])))
            }
        }
        return found
    }

    /// The Copilot CLI's fallback store: `copilot_tokens` keyed by
    /// `"https://github.com:<login>"`, the last signed-in user first.
    private static func cliCredentials(in environment: ProviderEnvironment) -> [Credential] {
        let url = environment.home.appendingPathComponent(".copilot/config.json")
        guard let object = ProviderJSON.readObject(at: url),
              let tokens = object["copilot_tokens"] as? [String: Any] else { return [] }
        var preferred: String?
        if let last = object["last_logged_in_user"] as? [String: Any],
           let host = ProviderJSON.string(last["host"]), let login = ProviderJSON.string(last["login"]) {
            preferred = "\(host):\(login)"
        }
        let keys = tokens.keys.sorted { lhs, rhs in
            lhs == preferred ? true : rhs == preferred ? false : lhs < rhs
        }
        return keys.compactMap { key in
            guard let token = cleanToken(tokens[key]), let host = hostPart(key) else { return nil }
            let rest = stripScheme(key).split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
            return Credential(host: host, token: token, user: rest.flatMap { ProviderJSON.string($0) })
        }
    }

    private static func cleanToken(_ value: Any?) -> String? {
        guard let token = ProviderJSON.string(value),
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return token
    }

    private static func stripScheme(_ value: String) -> String {
        for scheme in ["https://", "http://"] where value.lowercased().hasPrefix(scheme) {
            return String(value.dropFirst(scheme.count))
        }
        return value
    }

    /// "github.com:Iv1.b507…" / "https://github.com:octocat" → "github.com".
    private static func hostPart(_ key: String) -> String? {
        let host = stripScheme(key)
            .split(separator: ":", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() } ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return host
    }
}

private enum CopilotCalendar {
    /// Length of the calendar month (UTC) that ends at `reset`.
    static func monthLength(endingAt reset: Date) -> TimeInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let start = calendar.date(byAdding: .month, value: -1, to: reset) else { return nil }
        return reset.timeIntervalSince(start)
    }
}

private enum CopilotFormat {
    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// "individual_pro" → "Individual Pro".
    static func titleCased(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
