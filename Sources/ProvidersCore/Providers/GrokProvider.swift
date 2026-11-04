import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Grok (xAI) credits from the Grok CLI's billing proxy, read with the token
/// `grok login` keeps in `~/.grok/auth.json`. The CLI owns that token and its
/// refresh (a refresh here could rotate the CLI's refresh token away), so an
/// expired one is reported as a lapsed sign-in.
public struct GrokProvider: UsageProvider {
    public let id = "grok"
    public let name = "Grok"
    public let brandHex = "#8A8F98"
    public let symbol = "atom"
    public var dashboardURL: URL? { URL(string: "https://grok.com/?_s=usage") }

    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

    public init() {}

    public func isSignedIn(in environment: ProviderEnvironment) -> Bool {
        Self.credential(in: environment) != nil
    }

    public func fetch(in environment: ProviderEnvironment) async throws -> ProviderSnapshot {
        guard let credential = Self.credential(in: environment) else {
            throw ProviderFetchError.notSignedIn("No Grok CLI sign-in found. Run `grok login`.")
        }
        if let expiresAt = credential.expiresAt, expiresAt <= environment.now() {
            throw ProviderFetchError.unauthorized
        }
        let headers = [
            "Authorization": "Bearer \(credential.token)",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "User-Agent": "AgentProfiles",
        ]
        // The plan only comes from settings; it is optional enrichment.
        async let tier = Self.subscriptionTier(headers: headers, in: environment)
        let billing: [String: Any]
        do {
            billing = try await ProviderHTTP.object(ProviderHTTP.request(Self.billingURL, headers: headers), in: environment)
        } catch ProviderFetchError.http(412) {
            // "No personal team": a team principal has no personal quota.
            throw ProviderFetchError.unsupported("Grok team accounts have no personal quota.")
        }
        var snapshot = try Self.snapshot(from: billing, now: environment.now())
        snapshot.account = credential.email ?? credential.displayName
        snapshot.plan = await tier.map(Self.planName)
            ?? snapshot.plan
            ?? (credential.authMode?.lowercased() == "oidc" ? "SuperGrok" : nil)
        return snapshot
    }

    /// `subscription_tier_display` ("SuperGrok Heavy"), or nil on any failure.
    private static func subscriptionTier(headers: [String: String], in environment: ProviderEnvironment) async -> String? {
        let body = try? await ProviderHTTP.object(ProviderHTTP.request(settingsURL, headers: headers), in: environment)
        return ProviderJSON.string(body?["subscription_tier_display"])
    }

    // MARK: - Mapping

    static func snapshot(from body: [String: Any], now: Date) throws -> ProviderSnapshot {
        guard let config = body["config"] as? [String: Any] else { throw ProviderFetchError.invalidResponse }

        // The current period, else the billing period — never one's start
        // with the other's end.
        let current = config["currentPeriod"] as? [String: Any]
        var start: Date?
        var end = date(current?["end"])
        if end != nil {
            start = date(current?["start"])
        } else {
            end = date(config["billingPeriodEnd"])
            start = date(config["billingPeriodStart"])
        }
        let length: TimeInterval? = if let start, let end, end > start, start <= now { end.timeIntervalSince(start) } else { nil }

        // Proto-JSON omits zero values: no percent within a known period is
        // 0%, but a present non-number is a schema change.
        var percent: Double?
        if let raw = config["creditUsagePercent"] {
            guard let value = ProviderJSON.double(raw) else { throw ProviderFetchError.invalidResponse }
            percent = value
        } else if end != nil {
            percent = 0
        }

        var windows: [ProviderWindow] = []
        if let percent {
            windows.append(ProviderWindow(title: windowTitle(type: ProviderJSON.string(current?["type"]), length: length),
                                          usedPercent: percent, resetsAt: end, windowSeconds: length))
        }

        var details: [ProviderDetail] = []
        if let rawPercent = ProviderJSON.double(config["creditUsagePercent"]) {
            details += productShares(config["productUsage"], total: rawPercent)
        }
        // Money is `{ "val": <US cents> }`; an empty object is a zero proto3 scalar.
        if let cap = cents(config["onDemandCap"]), cap > 0 {
            let used = cents(config["onDemandUsed"]) ?? 0
            details.append(ProviderDetail(title: "On-demand", value: "\(dollars(used)) of \(dollars(cap))",
                                          usedPercent: min(100, used / cap * 100)))
        }
        if let balance = cents(config["prepaidBalance"]), balance >= 0 {
            details.append(ProviderDetail(title: "Balance", value: dollars(balance)))
        }
        guard !windows.isEmpty || !details.isEmpty else { throw ProviderFetchError.invalidResponse }

        let tier = ProviderJSON.string(config["subscriptionTier"]) ?? ProviderJSON.string(body["subscriptionTier"])
        return ProviderSnapshot(plan: tier.map(planName), windows: windows, details: details, fetchedAt: now)
    }

    private static func windowTitle(type: String?, length: TimeInterval?) -> String {
        let type = type?.uppercased() ?? ""
        if type.hasSuffix("WEEKLY") { return "Weekly" }
        if type.hasSuffix("MONTHLY") { return "Monthly" }
        guard let days = length.map({ $0 / 86400 }) else { return "Credits" }
        if abs(days - 7) < 0.5 { return "Weekly" }
        if (27.5...31.5).contains(days) { return "Monthly" }
        return "Credits"
    }

    /// Shares of the same pool by product ("GrokBuild" → "Grok Build 1%"),
    /// shown only when the whole list is well-formed and adds up to the total.
    private static func productShares(_ raw: Any?, total: Double) -> [ProviderDetail] {
        guard let items = raw as? [[String: Any]], !items.isEmpty else { return [] }
        var shares: [(String, Double)] = []
        for item in items {
            guard let product = ProviderJSON.string(item["product"]),
                  let share = ProviderJSON.double(item["usagePercent"] ?? 0), share >= 0 else { return [] }
            shares.append((product, share))
        }
        guard abs(shares.reduce(0) { $0 + $1.1 } - total) <= 1 else { return [] }
        return shares.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { ProviderDetail(title: spaced($0.0), value: percentText($0.1)) }
    }

    private static func cents(_ raw: Any?) -> Double? {
        guard let object = raw as? [String: Any] else { return nil }
        guard let value = object["val"] else { return object.isEmpty ? 0 : nil }
        return ProviderJSON.double(value)
    }

    private static func dollars(_ cents: Double) -> String { String(format: "$%.2f", cents / 100) }

    private static func percentText(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }

    /// "GrokAppBuilder" → "Grok App Builder".
    private static func spaced(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase, let last = result.last, last.isLowercase { result.append(" ") }
            result.append(character)
        }
        return result
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased().filter(\.isLetter) {
        case "supergrokheavy", "heavy": "SuperGrok Heavy"
        case "supergrok": "SuperGrok"
        default: raw
        }
    }

    /// ISO 8601; Grok writes microseconds ("…:00.123456+00:00"), which are
    /// cut to milliseconds when the shared parser refuses them.
    static func date(_ value: Any?) -> Date? {
        if let date = ProviderJSON.date(value) { return date }
        guard let text = ProviderJSON.string(value), let dot = text.firstIndex(of: ".") else { return nil }
        let fraction = text[text.index(after: dot)...].prefix { $0.isNumber }
        guard fraction.count > 3 else { return nil }
        let trimmed = String(text[..<dot]) + "." + String(fraction.prefix(3)) + String(text[fraction.endIndex...])
        return ProviderJSON.date(trimmed)
    }

    // MARK: - Credentials

    struct Credential: Equatable {
        var token: String
        var email: String?
        var displayName: String?
        var authMode: String?
        var expiresAt: Date?
    }

    static func authFileURL(in environment: ProviderEnvironment) -> URL {
        if let custom = ProviderJSON.string(environment.variables["GROK_HOME"]) {
            let path = custom.hasPrefix("~/") ? environment.home.appendingPathComponent(String(custom.dropFirst(2))).path : custom
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("auth.json")
        }
        return environment.home.appendingPathComponent(".grok/auth.json")
    }

    /// `auth.json` maps scope URLs to credentials: the SuperGrok OIDC scope
    /// (`https://auth.x.ai::<client id>`) first, then the legacy session one.
    static func credential(in environment: ProviderEnvironment) -> Credential? {
        guard let root = ProviderJSON.readObject(at: authFileURL(in: environment)) else { return nil }
        var oidc: [(String, [String: Any])] = []
        var legacy: [(String, [String: Any])] = []
        for (scope, value) in root {
            guard let entry = value as? [String: Any], token(entry["key"]) != nil else { continue }
            if scope.hasPrefix("https://auth.x.ai::") {
                oidc.append((scope, entry))
            } else if scope.contains("/sign-in") {
                legacy.append((scope, entry))
            }
        }
        // Several of a kind: the one that lasts longest.
        func best(_ entries: [(String, [String: Any])]) -> [String: Any]? {
            entries.max { lhs, rhs in
                let l = date(lhs.1["expires_at"]) ?? .distantPast, r = date(rhs.1["expires_at"]) ?? .distantPast
                return l == r ? lhs.0 > rhs.0 : l < r
            }?.1
        }
        guard let entry = best(oidc) ?? best(legacy), let key = token(entry["key"]) else { return nil }
        let name = [ProviderJSON.string(entry["first_name"]), ProviderJSON.string(entry["last_name"])]
            .compactMap { $0 }.joined(separator: " ")
        return Credential(token: key, email: ProviderJSON.string(entry["email"]),
                          displayName: name.isEmpty ? nil : name,
                          authMode: ProviderJSON.string(entry["auth_mode"]),
                          expiresAt: date(entry["expires_at"]))
    }

    private static func token(_ value: Any?) -> String? {
        guard let token = ProviderJSON.string(value),
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return token
    }
}
