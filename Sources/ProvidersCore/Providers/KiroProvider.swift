import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#endif

/// Kiro credits from `GetUsageLimits`, the service `kiro-cli` itself calls,
/// read with the CLI's own sign-in (its `data.sqlite3`, opened read-only).
/// The CLI owns that token and its refresh; when it has lapsed, running
/// `kiro-cli` renews it. Kiro IDE sign-ins are not read.
public struct KiroProvider: UsageProvider {
    public let id = "kiro"
    public let name = "Kiro"
    public let brandHex = "#9046FF"
    public let symbol = "wand.and.stars"
    public var dashboardURL: URL? { URL(string: "https://app.kiro.dev/account/usage") }

    /// The usage host follows the region in the CLI's profile ARN.
    static let endpoints = [
        "us-east-1": URL(string: "https://codewhisperer.us-east-1.amazonaws.com/")!,
        "eu-central-1": URL(string: "https://q.eu-central-1.amazonaws.com/")!,
    ]

    public init() {}

    public func isSignedIn(in environment: ProviderEnvironment) -> Bool {
        (try? Self.identity(in: environment)) != nil
    }

    public func fetch(in environment: ProviderEnvironment) async throws -> ProviderSnapshot {
        let identity = try Self.identity(in: environment)
        guard let endpoint = Self.endpoint(forProfileARN: identity.profileARN) else {
            throw ProviderFetchError.unsupported("Kiro profile region is not supported: \(identity.profileARN)")
        }
        var request = ProviderHTTP.request(endpoint, method: "POST", headers: [
            "Authorization": "Bearer \(identity.accessToken)",
            "Content-Type": "application/x-amz-json-1.0",
            "X-Amz-Target": "AmazonCodeWhispererService.GetUsageLimits",
        ])
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["profileArn": identity.profileARN])
        let body = try await ProviderHTTP.object(request, in: environment)
        return try Self.snapshot(from: body, fetchedAt: environment.now())
    }

    // MARK: - Mapping

    static func snapshot(from body: [String: Any], fetchedAt: Date) throws -> ProviderSnapshot {
        let credits = (body["usageBreakdownList"] as? [[String: Any]] ?? [])
            .filter { ProviderJSON.string($0["resourceType"])?.uppercased() == "CREDIT" }
        // None, or several with no single authoritative ceiling.
        guard credits.count == 1, let credit = credits.first,
              let limit = nonNegative(credit["usageLimitWithPrecision"] ?? credit["usageLimit"]),
              let total = nonNegative(credit["currentUsageWithPrecision"] ?? credit["currentUsage"]),
              let overage = nonNegative(credit["currentOveragesWithPrecision"] ?? credit["currentOverages"] ?? 0),
              total >= overage
        else { throw ProviderFetchError.invalidResponse }

        let resetsAt = ProviderJSON.date(credit["nextDateReset"] ?? body["nextDateReset"])
        let windowSeconds = resetsAt.flatMap(KiroCalendar.monthLength(endingAt:))
        // `currentUsage` includes overage, so the plan's share is the rest.
        let planUsed = total - overage
        // With bonus credits on the account, `currentUsage` folds their spend
        // in too and the plan's share can't be split out.
        let hasBonus = !((credit["bonuses"] as? [Any]) ?? []).isEmpty

        var windows: [ProviderWindow] = []
        var details: [ProviderDetail] = []
        if !hasBonus, limit > 0 {
            guard planUsed <= limit else { throw ProviderFetchError.invalidResponse }
            windows.append(ProviderWindow(title: "Credits", usedPercent: planUsed / limit * 100,
                                          resetsAt: resetsAt, windowSeconds: windowSeconds))
            details.append(ProviderDetail(title: "Credits", value: "\(KiroFormat.number(planUsed)) / \(KiroFormat.number(limit))"))
        } else {
            details.append(ProviderDetail(title: "Credits used", value: hasBonus
                ? "\(KiroFormat.number(total)) incl. bonus" : KiroFormat.number(total)))
        }

        let overageConfig = body["overageConfiguration"] as? [String: Any]
        let overageEnabled = ProviderJSON.string(overageConfig?["overageStatus"])?.uppercased() == "ENABLED"
        if overageEnabled, let cap = nonNegative(credit["overageCapWithPrecision"] ?? credit["overageCap"]), cap > 0 {
            windows.append(ProviderWindow(title: "Overage", usedPercent: overage / cap * 100,
                                          resetsAt: resetsAt, windowSeconds: windowSeconds))
            let currency = ProviderJSON.string(credit["currency"]) ?? "USD"
            if let charges = nonNegative(credit["overageCharges"]) {
                let rate = ProviderJSON.double(credit["overageRate"]).flatMap { $0 > 0 ? $0 : nil }
                let value = rate.map { "\(KiroFormat.money(charges, currency)) of \(KiroFormat.money(cap * $0, currency))" }
                    ?? KiroFormat.money(charges, currency)
                details.append(ProviderDetail(title: "Overage charges", value: value,
                                              usedPercent: rate.map { charges / (cap * $0) * 100 }))
            }
        }

        let info = body["subscriptionInfo"] as? [String: Any]
        return ProviderSnapshot(
            plan: ProviderJSON.string(info?["subscriptionTitle"]).map(KiroFormat.plan),
            windows: windows,
            details: details,
            fetchedAt: fetchedAt)
    }

    private static func nonNegative(_ value: Any?) -> Double? {
        guard let number = ProviderJSON.double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }

    /// `arn:aws:codewhisperer:<region>:<account>:profile/<id>` → that
    /// region's host; nil for anything else, so a token never goes to a
    /// guessed host.
    static func endpoint(forProfileARN arn: String) -> URL? {
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "arn", parts[1] == "aws", parts[2] == "codewhisperer",
              parts[5].hasPrefix("profile/"), parts[5].count > "profile/".count,
              arn.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return nil }
        return endpoints[String(parts[3])]
    }

    // MARK: - Credentials

    struct Identity: Equatable {
        var accessToken: String
        var profileARN: String
    }

    /// `KIRO_DATA_DIR`, else `~/Library/Application Support/kiro-cli` on
    /// macOS and `$XDG_DATA_HOME/kiro-cli` (`~/.local/share`) elsewhere.
    static func databaseURL(in environment: ProviderEnvironment) -> URL {
        if let override = ProviderJSON.string(environment.variables["KIRO_DATA_DIR"]) {
            let path = override.hasPrefix("~/")
                ? environment.home.appendingPathComponent(String(override.dropFirst(2))).path : override
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("data.sqlite3")
        }
        #if os(macOS)
        return environment.home.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
        #else
        let dataHome = ProviderJSON.string(environment.variables["XDG_DATA_HOME"]).flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
        } ?? environment.home.appendingPathComponent(".local/share", isDirectory: true)
        return dataHome.appendingPathComponent("kiro-cli/data.sqlite3")
        #endif
    }

    static func identity(in environment: ProviderEnvironment) throws -> Identity {
        let hint = "No Kiro CLI sign-in found. Run `kiro-cli login`."
        let url = databaseURL(in: environment)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ProviderFetchError.notSignedIn(hint) }
        #if canImport(SQLite3)
        let values = KiroSQLite.read(url) { db in
            (KiroSQLite.text(db, "SELECT value FROM auth_kv WHERE key = 'kirocli:odic:token'"),
             KiroSQLite.text(db, "SELECT value FROM state WHERE key = 'api.codewhisperer.profile'"))
        }
        guard let values,
              let token = values.0.flatMap(jsonString(key: "access_token")),
              let arn = values.1.flatMap(jsonString(key: "arn"))
        else { throw ProviderFetchError.notSignedIn(hint) }
        return Identity(accessToken: token, profileARN: arn)
        #else
        throw ProviderFetchError.notSignedIn("Reading the Kiro CLI sign-in needs SQLite, which this build lacks.")
        #endif
    }

    private static func jsonString(key: String) -> (String) -> String? {
        { json in
            guard let data = json.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let value = ProviderJSON.string(object[key]),
                  value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
            else { return nil }
            return value
        }
    }
}

private enum KiroCalendar {
    /// Length of the calendar month (UTC) that ends at `reset`.
    static func monthLength(endingAt reset: Date) -> TimeInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let start = calendar.date(byAdding: .month, value: -1, to: reset) else { return nil }
        return reset.timeIntervalSince(start)
    }
}

private enum KiroFormat {
    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(format: "%.2f", value)
    }

    static func money(_ value: Double, _ currency: String) -> String {
        currency.uppercased() == "USD" ? String(format: "$%.2f", value) : String(format: "%.2f \(currency)", value)
    }

    /// "KIRO PRO+" → "Pro+", "KIRO POWER" → "Power".
    static func plan(_ title: String) -> String {
        var words = title.split(separator: " ").map(String.init)
        if words.count > 1, words[0].lowercased() == "kiro" { words.removeFirst() }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}

#if canImport(SQLite3)
private enum KiroSQLite {
    /// Opens `url` read-only (never creating or migrating it). A database left
    /// in WAL mode without its sidecars is opened immutable instead.
    static func read<T>(_ url: URL, _ body: (OpaquePointer) -> T) -> T? {
        func attempt(immutable: Bool) -> T? {
            var db: OpaquePointer?
            let name = immutable ? "\(url.absoluteURL.absoluteString)?immutable=1" : url.path
            let flags = SQLITE_OPEN_READONLY | (immutable ? SQLITE_OPEN_URI : 0)
            defer { sqlite3_close(db) }
            guard sqlite3_open_v2(name, &db, flags, nil) == SQLITE_OK, let db else { return nil }
            sqlite3_busy_timeout(db, 250)
            guard sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK else { return nil }
            return body(db)
        }
        if let result = attempt(immutable: false) { return result }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path + "-wal"), !fm.fileExists(atPath: url.path + "-shm") else { return nil }
        return attempt(immutable: true)
    }

    /// First column of the first row, or nil.
    static func text(_ db: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}
#endif
