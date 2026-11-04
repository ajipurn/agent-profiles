import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#endif

/// OpenCode Go: the subscription's 5-hour, weekly and monthly caps from the
/// public usage API, read with the key the OpenCode CLI keeps (v2
/// `credential` table in `opencode.db`, or the older `auth.json`), or
/// `OPENCODE_API_KEY`. The Zen pay-as-you-go balance is only on the
/// cookie-authenticated console, so it is not shown.
public struct OpenCodeProvider: UsageProvider {
    public let id = "opencode"
    public let name = "OpenCode"
    public let brandHex = "#3B82F6"
    public let symbol = "terminal"
    public var dashboardURL: URL? { URL(string: "https://opencode.ai/auth") }

    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    static let sessionSeconds: TimeInterval = 5 * 3600
    static let weekSeconds: TimeInterval = 7 * 86400

    public init() {}

    public func isSignedIn(in environment: ProviderEnvironment) -> Bool {
        Self.credential(in: environment) != nil
    }

    public func fetch(in environment: ProviderEnvironment) async throws -> ProviderSnapshot {
        switch Self.credential(in: environment) {
        case nil:
            throw ProviderFetchError.notSignedIn(
                "No OpenCode Go sign-in found. Run `opencode auth login` and choose OpenCode Go, or set OPENCODE_API_KEY.")
        case .expired:
            throw ProviderFetchError.unauthorized
        case .token(let token):
            let request = ProviderHTTP.request(Self.usageURL, headers: [
                "Authorization": "Bearer \(token)",
                "User-Agent": "AgentProfiles",
            ])
            // Not `ProviderHTTP.object`: a 403 only means "signed out" when it
            // is not OpenCode's EntitlementError (no Go subscription).
            let (data, response) = try await environment.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderFetchError.invalidResponse }
            switch http.statusCode {
            case 200...299:
                break
            case 403 where Self.errorType(in: data) == "EntitlementError":
                throw ProviderFetchError.unsupported("No OpenCode Go subscription on this account.")
            case 401, 403:
                throw ProviderFetchError.unauthorized
            default:
                throw ProviderFetchError.http(http.statusCode)
            }
            guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ProviderFetchError.invalidResponse
            }
            return try Self.snapshot(from: body, now: environment.now())
        }
    }

    // MARK: - Mapping

    static func snapshot(from body: [String: Any], now: Date) throws -> ProviderSnapshot {
        guard let usage = body["usage"] as? [String: Any],
              let session = window("Session", usage["rolling"], seconds: sessionSeconds, now: now,
                                   dropsPlaceholderReset: true)
        else { throw ProviderFetchError.invalidResponse }
        var windows = [session]
        if let weekly = window("Weekly", usage["weekly"], seconds: weekSeconds, now: now) {
            windows.append(weekly)
        }
        if let monthly = window("Monthly", usage["monthly"], seconds: nil, now: now) {
            windows.append(monthly)
        }
        return ProviderSnapshot(plan: "Go", windows: windows, fetchedAt: now)
    }

    /// `percent` is already 0–100. The reset is `resetsAt` (ISO 8601) or
    /// `resetInSec`. An untouched rolling window reports `now + 5h` as its
    /// reset on every call; that is "if you started now", so it is dropped.
    private static func window(_ title: String, _ raw: Any?, seconds: TimeInterval?, now: Date,
                               dropsPlaceholderReset: Bool = false) -> ProviderWindow? {
        guard let object = raw as? [String: Any],
              let percent = ProviderJSON.double(object["percent"] ?? object["usagePercent"]) else { return nil }
        var resetsAt = ProviderJSON.date(object["resetsAt"] ?? object["resetAt"])
        if resetsAt == nil, let inSeconds = ProviderJSON.double(object["resetInSec"]), inSeconds >= 0 {
            resetsAt = now.addingTimeInterval(inSeconds)
        }
        if dropsPlaceholderReset, percent == 0, let reset = resetsAt, let seconds,
           abs(reset.timeIntervalSince(now) - seconds) <= 2 {
            resetsAt = nil
        }
        var length = seconds
        if length == nil, let resetsAt {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
            length = calendar.date(byAdding: .month, value: -1, to: resetsAt).map { resetsAt.timeIntervalSince($0) }
        }
        return ProviderWindow(title: title, usedPercent: percent, resetsAt: resetsAt, windowSeconds: length)
    }

    static func errorType(in data: Data) -> String? {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = body["error"] as? [String: Any] else { return nil }
        return ProviderJSON.string(error["type"])
    }

    // MARK: - Credentials

    enum Credential: Equatable {
        case token(String)
        /// An OAuth login past its expiry; OpenCode renews it on its next run.
        case expired
    }

    /// `OPENCODE_API_KEY`, else the CLI's v2 credential table (`opencode-go`
    /// before `opencode`), else — only when that table does not exist — the
    /// `opencode-go` key in the older `auth.json`.
    static func credential(in environment: ProviderEnvironment) -> Credential? {
        if let key = cleanToken(environment.variables["OPENCODE_API_KEY"]) { return .token(key) }
        let dataHome = ProviderJSON.string(environment.variables["XDG_DATA_HOME"]).flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
        } ?? environment.home.appendingPathComponent(".local/share", isDirectory: true)
        let directory = dataHome.appendingPathComponent("opencode", isDirectory: true)

        let databaseName = ProviderJSON.string(environment.variables["OPENCODE_DB"]) ?? "opencode.db"
        if databaseName != ":memory:" {
            let database = databaseName.hasPrefix("/") ? URL(fileURLWithPath: databaseName)
                : directory.appendingPathComponent(databaseName)
            if let rows = OpenCodeCredentialTable.activeRows(in: database) {
                return rows.lazy.compactMap { credential(fromJSON: $0, now: environment.now()) }.first
            }
        }
        guard let auth = ProviderJSON.readObject(at: directory.appendingPathComponent("auth.json")),
              let entry = auth["opencode-go"] as? [String: Any],
              ProviderJSON.string(entry["type"]) == "api",
              let key = cleanToken(entry["key"]) else { return nil }
        return .token(key)
    }

    /// `{"type":"key","key":…}` or `{"type":"oauth","access":…,"expires":<ms>}`.
    private static func credential(fromJSON json: String, now: Date) -> Credential? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch ProviderJSON.string(object["type"]) {
        case "key", "api":
            return cleanToken(object["key"]).map(Credential.token)
        case "oauth":
            guard let access = cleanToken(object["access"]) else { return nil }
            if let expires = ProviderJSON.date(object["expires"]), expires <= now { return .expired }
            return .token(access)
        default:
            return nil
        }
    }

    private static func cleanToken(_ value: Any?) -> String? {
        guard let token = ProviderJSON.string(value),
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return token
    }
}

/// Read-only access to the OpenCode CLI's `credential` table.
private enum OpenCodeCredentialTable {
    /// The `value` JSON of active rows, preferred integration first; nil when
    /// the database or the table does not exist (so `auth.json` applies).
    static func activeRows(in database: URL) -> [String]? {
        #if canImport(SQLite3)
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        return OpenCodeSQLite.read(database) { db -> [String]? in
            guard let tables = OpenCodeSQLite.texts(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'credential'"),
                  !tables.isEmpty else { return nil }
            return OpenCodeSQLite.texts(db, """
                SELECT value FROM credential
                WHERE active = 1 AND integration_id IN ('opencode-go', 'opencode')
                ORDER BY CASE integration_id WHEN 'opencode-go' THEN 0 ELSE 1 END, rowid DESC
                """) ?? []
        }
        #else
        return nil
        #endif
    }
}

#if canImport(SQLite3)
private enum OpenCodeSQLite {
    /// Opens `url` read-only (never creating or migrating it). A database left
    /// in WAL mode without its sidecars is opened immutable instead.
    static func read<T>(_ url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        func attempt(immutable: Bool) -> T?? {
            var db: OpaquePointer?
            let name = immutable ? "\(url.absoluteURL.absoluteString)?immutable=1" : url.path
            let flags = SQLITE_OPEN_READONLY | (immutable ? SQLITE_OPEN_URI : 0)
            defer { sqlite3_close(db) }
            guard sqlite3_open_v2(name, &db, flags, nil) == SQLITE_OK, let db else { return nil }
            sqlite3_busy_timeout(db, 250)
            // Probe once so an unopenable WAL surfaces here, not as "no rows".
            guard sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK else { return nil }
            return .some(body(db))
        }
        if let result = attempt(immutable: false) { return result }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path + "-wal"), !fm.fileExists(atPath: url.path + "-shm") else { return nil }
        return attempt(immutable: true) ?? nil
    }

    /// First-column text of every row, or nil when the statement fails.
    static func texts(_ db: OpaquePointer, _ sql: String) -> [String]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }
}
#endif
