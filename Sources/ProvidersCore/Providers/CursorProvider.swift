import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#endif
import PlatformSupport

/// Cursor plan usage from cursor.com's dashboard API, signed in with the
/// session the Cursor app keeps in its global state database
/// (`cursorAuth/accessToken`), or the one `cursor-agent login` leaves in
/// `~/.config/cursor/auth.json`. Browser cookies and tokens Cursor encrypts
/// with its Keychain key are not read (both prompt). The session is never
/// refreshed here: Cursor renews its own.
public struct CursorProvider: UsageProvider {
    public let id = "cursor"
    public let name = "Cursor"
    public let brandHex = "#F54E00"
    public let symbol = "cursorarrow"
    public var dashboardURL: URL? { URL(string: "https://cursor.com/dashboard?tab=usage") }
    public var statusPageURL: URL? { URL(string: "https://status.cursor.com") }

    public init() {}

    public func isSignedIn(in environment: ProviderEnvironment) -> Bool {
        !Self.storedTokens(in: environment).isEmpty
    }

    public func fetch(in environment: ProviderEnvironment) async throws -> ProviderSnapshot {
        let tokens = Self.storedTokens(in: environment)
        guard !tokens.isEmpty else {
            throw ProviderFetchError.notSignedIn("No Cursor sign-in found. Open Cursor and sign in, or run `cursor-agent login`.")
        }
        let readable = tokens.filter { !$0.hasPrefix("cursor-safe-storage:") }
        guard !readable.isEmpty else {
            throw ProviderFetchError.unsupported(
                "Cursor keeps this sign-in encrypted with a Keychain key, which Agent Profiles doesn't read.")
        }
        let sessions = readable.compactMap(Session.init(token:))
        guard !sessions.isEmpty else {
            throw ProviderFetchError.notSignedIn("Cursor's saved sign-in couldn't be read. Sign in to Cursor again.")
        }
        let now = environment.now()
        let usable = sessions.filter { $0.expiresAt.map { $0.timeIntervalSince(now) > 60 } ?? true }
        guard !usable.isEmpty else { throw ProviderFetchError.unauthorized }
        // A refused app session falls through to the cursor-agent one.
        for (index, session) in usable.enumerated() {
            do {
                return try await Self.fetch(session, in: environment)
            } catch ProviderFetchError.unauthorized where index < usable.count - 1 {
                continue
            }
        }
        throw ProviderFetchError.unauthorized
    }

    // MARK: - Session

    struct Session: Equatable {
        var token: String
        var userID: String
        var email: String?
        var expiresAt: Date?

        /// The access token is a JWT whose `sub` is `auth0|user_…`.
        init?(token: String) {
            guard let claims = ProviderJSON.jwtClaims(token),
                  let subject = ProviderJSON.string(claims["sub"]),
                  let userID = subject.split(separator: "|").last.map(String.init), !userID.isEmpty
            else { return nil }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            guard userID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            self.token = token
            self.userID = userID
            self.email = ProviderJSON.string(claims["email"])
            self.expiresAt = ProviderJSON.date(claims["exp"])
        }

        /// cursor.com takes the app token as its web session cookie.
        var cookie: String { "WorkosCursorSessionToken=\(userID)%3A%3A\(token)" }
    }

    // MARK: - Local sign-ins

    static func stateDatabaseURL(_ environment: ProviderEnvironment) -> URL {
        var appData = PlatformPaths.appData(home: environment.home)
        #if os(Linux)
        if let configHome = ProviderJSON.string(environment.variables["XDG_CONFIG_HOME"]), configHome.hasPrefix("/") {
            appData = URL(fileURLWithPath: configHome, isDirectory: true)
        }
        #endif
        appData.appendPathComponent("Cursor/User/globalStorage/state.vscdb")
        return appData
    }

    static func agentAuthURL(_ environment: ProviderEnvironment) -> URL {
        if let configHome = ProviderJSON.string(environment.variables["XDG_CONFIG_HOME"]), configHome.hasPrefix("/") {
            return URL(fileURLWithPath: configHome, isDirectory: true).appendingPathComponent("cursor/auth.json")
        }
        return environment.home.appendingPathComponent(".config/cursor/auth.json")
    }

    /// The Cursor app's token, then cursor-agent's, as stored.
    static func storedTokens(in environment: ProviderEnvironment) -> [String] {
        var tokens: [String] = []
        if let token = CursorStateDatabase.accessToken(at: stateDatabaseURL(environment)) {
            tokens.append(token)
        }
        if let json = ProviderJSON.readObject(at: agentAuthURL(environment)),
           let token = ProviderJSON.string(json["accessToken"]), !tokens.contains(token) {
            tokens.append(token)
        }
        return tokens
    }

    // MARK: - Requests

    static let baseURL = URL(string: "https://cursor.com")!

    static func fetch(_ session: Session, in environment: ProviderEnvironment) async throws -> ProviderSnapshot {
        let cookie = ["Cookie": session.cookie]
        let summaryRequest = ProviderHTTP.request(baseURL.appendingPathComponent("api/usage-summary"), headers: cookie)
        let meRequest = ProviderHTTP.request(baseURL.appendingPathComponent("api/auth/me"), headers: cookie)
        let sandRequest = ProviderHTTP.request(
            baseURL.appendingPathComponent("api/dashboard/get-sand-usage-status"), method: "POST",
            headers: cookie.merging(["Origin": "https://cursor.com"]) { $1 }, jsonBody: [String: Any]())

        async let meData = optionalData(meRequest, in: environment)
        async let sandData = optionalData(sandRequest, in: environment)
        let summary = try await ProviderHTTP.object(summaryRequest, in: environment)
        let me = await meData.flatMap(object)
        let sand = await sandData.flatMap(object)

        // Legacy request-based plans report their quota here; unified billing has none.
        var requestUsage: [String: Any]?
        if !usesUnifiedBilling(summary) {
            let userID = ProviderJSON.string(me?["sub"]).flatMap { $0.split(separator: "|").last.map(String.init) }
                ?? session.userID
            var components = URLComponents(url: baseURL.appendingPathComponent("api/usage"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "user", value: userID)]
            if let url = components?.url {
                requestUsage = await optionalData(ProviderHTTP.request(url, headers: cookie), in: environment).flatMap(object)
            }
        }
        return snapshot(summary: summary, me: me, requestUsage: requestUsage, sand: sand,
                        session: session, now: environment.now())
    }

    /// A best-effort extra read: nil on any failure.
    static func optionalData(_ request: URLRequest, in environment: ProviderEnvironment) async -> Data? {
        guard let (data, response) = try? await environment.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else { return nil }
        return data
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func usesUnifiedBilling(_ summary: [String: Any]) -> Bool {
        ProviderJSON.string(summary["membershipType"])?.lowercased().hasPrefix("unified_") == true
            && ProviderJSON.string(summary["limitType"])?.lowercased() == "user"
    }

    // MARK: - Mapping

    static let week: TimeInterval = 7 * 86_400

    static func snapshot(summary: [String: Any], me: [String: Any]?, requestUsage: [String: Any]?,
                         sand: [String: Any]?, session: Session, now: Date) -> ProviderSnapshot {
        let cycleStart = ProviderJSON.date(summary["billingCycleStart"])
        let cycleEnd = ProviderJSON.date(summary["billingCycleEnd"])
        let cycleSeconds = cycleStart.flatMap { start in cycleEnd.map { $0.timeIntervalSince(start) } }.flatMap { $0 > 0 ? $0 : nil }
        func monthly(_ title: String, _ percent: Double) -> ProviderWindow {
            ProviderWindow(title: title, usedPercent: percent, resetsAt: cycleEnd, windowSeconds: cycleSeconds)
        }

        let individual = summary["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let overall = individual?["overall"] as? [String: Any]
        let onDemand = individual?["onDemand"] as? [String: Any]
        let team = summary["teamUsage"] as? [String: Any]
        let pooled = team?["pooled"] as? [String: Any]
        let teamOnDemand = team?["onDemand"] as? [String: Any]

        // Percent fields are already percentages, fractional ones included.
        let auto = ProviderJSON.double(plan?["autoPercentUsed"])
        let api = ProviderJSON.double(plan?["apiPercentUsed"])
        func share(_ block: [String: Any]?) -> Double? {
            guard let used = ProviderJSON.double(block?["used"]), let limit = ProviderJSON.double(block?["limit"]),
                  limit > 0 else { return nil }
            return used / limit * 100
        }
        let averaged = auto.flatMap { auto in api.map { (auto + $0) / 2 } }
        let total = ProviderJSON.double(plan?["totalPercentUsed"]) ?? averaged ?? api ?? auto
            ?? share(plan) ?? share(overall) ?? share(pooled) ?? 0

        let gpt4 = requestUsage?["gpt-4"] as? [String: Any]
        let requestLimit = ProviderJSON.double(gpt4?["maxRequestUsage"]).flatMap { $0 > 0 ? $0 : nil }
        let requestsUsed = ProviderJSON.double(gpt4?["numRequestsTotal"]) ?? ProviderJSON.double(gpt4?["numRequests"]) ?? 0
        let grokBot = grokBotWindow(sand, now: now)

        var windows: [ProviderWindow] = []
        var details: [ProviderDetail] = []
        if let requestLimit {
            windows.append(monthly("Requests", requestsUsed / requestLimit * 100))
            details.append(ProviderDetail(title: "Requests", value: "\(Int(requestsUsed)) of \(Int(requestLimit))",
                                          usedPercent: min(100, requestsUsed / requestLimit * 100)))
        } else if ProviderJSON.bool(sand?["isUnified"]) == true, let grokBot, grokBot.windowSeconds == week,
                  let resetsAt = grokBot.resetsAt, resetsAt > now {
            // The X Subscription's shared weekly pool replaces the stale monthly bars.
            windows.append(ProviderWindow(title: "Weekly", usedPercent: grokBot.usedPercent,
                                          resetsAt: resetsAt, windowSeconds: week))
        } else {
            windows.append(monthly("Monthly", total))
            if let auto { windows.append(monthly("Auto", auto)) }
            if let api { windows.append(monthly("API", api)) }
            if let grokBot { windows.append(grokBot) }
        }

        if requestLimit == nil, let used = cents(plan?["used"]), let limit = cents(plan?["limit"]), limit > 0 {
            details.append(ProviderDetail(title: "Included", value: "\(dollars(used)) of \(dollars(limit))",
                                          usedPercent: min(100, used / limit * 100)))
        }
        let personalUsed = cents(onDemand?["used"]) ?? 0
        if let limit = cents(onDemand?["limit"]), limit > 0 {
            details.append(ProviderDetail(title: "On-demand", value: "\(dollars(personalUsed)) of \(dollars(limit))",
                                          usedPercent: min(100, personalUsed / limit * 100)))
        } else if let limit = cents(teamOnDemand?["limit"]), limit > 0 {
            let used = cents(teamOnDemand?["used"]) ?? 0
            details.append(ProviderDetail(title: "Team on-demand", value: "\(dollars(used)) of \(dollars(limit))",
                                          usedPercent: min(100, used / limit * 100)))
            if personalUsed > 0 { details.append(ProviderDetail(title: "On-demand", value: dollars(personalUsed))) }
        } else if personalUsed > 0 {
            details.append(ProviderDetail(title: "On-demand", value: dollars(personalUsed)))
        }

        return ProviderSnapshot(
            account: ProviderJSON.string(me?["email"]) ?? session.email,
            plan: planName(ProviderJSON.string(summary["membershipType"])),
            windows: windows,
            details: details,
            fetchedAt: now)
    }

    /// Grok Bot ("Sand"): a paid weekly allowance, or an unexpired trial
    /// (whose expiry is not a reset).
    static func grokBotWindow(_ sand: [String: Any]?, now: Date) -> ProviderWindow? {
        guard let sand, ProviderJSON.bool(sand["usesPooledEnterpriseAllowance"]) != true else { return nil }
        let hasLimit = ProviderJSON.bool(sand["includedLimitZero"]).map { !$0 } ?? ProviderJSON.bool(sand["hasNonZeroIncludedLimit"])
        let hasTrial = hasLimit != true && (ProviderJSON.date(sand["sandTrialExpiresAt"]).map { $0 > now } ?? false)
        guard hasLimit == true || hasTrial, let percent = ProviderJSON.double(sand["usagePercent"]), percent >= 0 else {
            return nil
        }
        let resetsAt = hasTrial ? nil : ProviderJSON.date(sand["nextResetTimestampUtc"])
        return ProviderWindow(title: "Grok Bot", usedPercent: percent, resetsAt: resetsAt,
                              windowSeconds: resetsAt == nil ? nil : week)
    }

    static func planName(_ membership: String?) -> String? {
        guard var type = membership?.lowercased() else { return nil }
        if type.hasPrefix("unified_") { type.removeFirst("unified_".count) }
        let names = [
            "enterprise": "Enterprise", "business": "Business", "express": "Start", "free": "Free",
            "free_trial": "Pro Trial", "hobby": "Hobby", "pro": "Pro", "pro_student": "Pro", "pro_plus": "Pro+",
            "team": "Team", "teams": "Team", "ultra": "Ultra",
        ]
        if let name = names[type] { return name }
        return type.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func cents(_ value: Any?) -> Double? {
        ProviderJSON.double(value)
    }

    private static func dollars(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }
}

/// Read-only access to Cursor's VS Code-style `state.vscdb`.
private enum CursorStateDatabase {
    static func accessToken(at url: URL) -> String? {
        #if canImport(SQLite3)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        switch read(url, immutable: false) {
        case .success(let token):
            return token
        case .failure(let failure):
            // An idle WAL database whose sidecars are gone opens only as
            // immutable; never use that while a WAL exists (it would skip
            // uncheckpointed state), and never create sidecars in Cursor's folder.
            let fileManager = FileManager.default
            guard failure.code == SQLITE_CANTOPEN,
                  !fileManager.fileExists(atPath: url.path + "-wal"),
                  !fileManager.fileExists(atPath: url.path + "-shm") else { return nil }
            return try? read(url, immutable: true).get()
        }
        #else
        return nil
        #endif
    }

    #if canImport(SQLite3)
    private struct Failure: Error {
        var code: Int32
    }

    private static func read(_ url: URL, immutable: Bool) -> Result<String?, Failure> {
        var db: OpaquePointer?
        let filename = immutable ? url.absoluteURL.absoluteString + "?immutable=1" : url.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let opened = sqlite3_open_v2(filename, &db, flags, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { return .failure(Failure(code: db.map(sqlite3_errcode) ?? opened)) }
        sqlite3_busy_timeout(db, 250)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return .failure(Failure(code: sqlite3_errcode(db)))
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return .success(value(statement))
        case SQLITE_DONE: return .success(nil)
        default: return .failure(Failure(code: sqlite3_errcode(db)))
        }
    }

    private static func value(_ statement: OpaquePointer?) -> String? {
        let raw: String?
        switch sqlite3_column_type(statement, 0) {
        case SQLITE_TEXT:
            raw = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            // ASCII stored as UTF-16LE is also valid UTF-8 with NULs, so check it first.
            let isUTF16 = !data.isEmpty && data.count.isMultiple(of: 2)
                && stride(from: 0, to: data.count, by: 2).allSatisfy { (1..<128).contains(data[$0]) && data[$0 + 1] == 0 }
            raw = isUTF16 ? String(data: data, encoding: .utf16LittleEndian) : String(data: data, encoding: .utf8)
        default:
            raw = nil
        }
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        if token.count > 1, token.hasPrefix("\""), token.hasSuffix("\"") { token = String(token.dropFirst().dropLast()) }
        return token.isEmpty ? nil : token
    }
    #endif
}
