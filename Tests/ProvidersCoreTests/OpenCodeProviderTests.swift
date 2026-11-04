import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
@testable import ProvidersCore

/// Answers every request with the stubbed status and body, recording what
/// was asked. One suite uses it at a time (the suite is serialized).
final class OpenCodeStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (200, Data())
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(status: Int = 200, body: Data = Data()) {
        response = (status, body)
        requests = []
    }
}

@Suite(.serialized) struct OpenCodeProviderTests {
    static let now = Date(timeIntervalSince1970: 1_793_872_800) // 2026-11-05T10:00:00Z

    /// A fake home, created on first install and removed by `cleanUp`.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-tests-\(UUID().uuidString)")
    var dataDirectory: URL { home.appendingPathComponent(".local/share/opencode") }

    func environment(variables: [String: String] = [:]) -> ProviderEnvironment {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenCodeStubURLProtocol.self]
        return ProviderEnvironment(home: home, session: URLSession(configuration: config),
                                   now: { Self.now }, variables: variables)
    }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func object(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    }

    func installAuthJSON() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try Self.fixture("opencode-auth").write(to: dataDirectory.appendingPathComponent("auth.json"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    static func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }

    // MARK: Mapping

    @Test func nowIsTheMorningOfNovemberFifth() {
        #expect(Self.now == Self.utc("2026-11-05T10:00:00.000Z"))
    }

    @Test func mapsSessionWeeklyAndMonthlyWindows() throws {
        let snapshot = try OpenCodeProvider.snapshot(from: Self.object("opencode-usage"), now: Self.now)
        #expect(snapshot.plan == "Go")
        #expect(snapshot.account == nil)
        #expect(snapshot.windows.map(\.title) == ["Session", "Weekly", "Monthly"])
        #expect(snapshot.windows.map(\.usedPercent) == [22, 44.5, 55])
        #expect(snapshot.windows.map(\.resetsAt) == [
            Self.utc("2026-11-05T13:00:00.000Z"), Self.utc("2026-11-10T00:00:00.000Z"), Self.utc("2026-12-01T00:00:00.000Z"),
        ])
        let lengths: [TimeInterval?] = [18_000, 604_800, 2_592_000] // 5 h, 7 d, November
        #expect(snapshot.windows.map(\.windowSeconds) == lengths)
    }

    @Test func idleSessionDropsItsPlaceholderReset() throws {
        let snapshot = try OpenCodeProvider.snapshot(from: Self.object("opencode-usage-idle"), now: Self.now)
        #expect(snapshot.windows.map(\.title) == ["Session", "Weekly"])
        #expect(snapshot.windows[0].resetsAt == nil)
        // `resetInSec` counts from now.
        #expect(snapshot.windows[1].resetsAt == Self.now.addingTimeInterval(86400))
    }

    @Test func missingRollingUsageIsInvalid() {
        #expect(throws: ProviderFetchError.invalidResponse) {
            try OpenCodeProvider.snapshot(from: ["usage": ["weekly": ["percent": 1]]], now: Self.now)
        }
        #expect(throws: ProviderFetchError.invalidResponse) {
            try OpenCodeProvider.snapshot(from: [:], now: Self.now)
        }
    }

    // MARK: Credentials and requests

    @Test func missingFilesAreNotSignedIn() async {
        OpenCodeStubURLProtocol.reset()
        let provider = OpenCodeProvider()
        #expect(!provider.isSignedIn(in: environment()))
        do {
            _ = try await provider.fetch(in: environment())
            Issue.record("fetch succeeded without a sign-in")
        } catch {
            guard case .notSignedIn? = error as? ProviderFetchError else { Issue.record("unexpected \(error)"); return }
        }
        #expect(OpenCodeStubURLProtocol.requests.isEmpty)
    }

    @Test func fetchesWithLegacyAuthJSONKey() async throws {
        defer { cleanUp() }
        try installAuthJSON()
        OpenCodeStubURLProtocol.reset(body: try Self.fixture("opencode-usage"))
        let provider = OpenCodeProvider()
        #expect(provider.isSignedIn(in: environment()))

        let snapshot = try await provider.fetch(in: environment())
        #expect(snapshot.windows.count == 3)
        let request = try #require(OpenCodeStubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://opencode.ai/zen/go/v1/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer go_FAKEauthJSONkey0000")
    }

    @Test func environmentKeyWinsOverFiles() throws {
        defer { cleanUp() }
        try installAuthJSON()
        let credential = OpenCodeProvider.credential(in: environment(variables: ["OPENCODE_API_KEY": " go_FAKEenv "]))
        #expect(credential == .token("go_FAKEenv"))
    }

    @Test func honorsXDGDataHome() throws {
        defer { cleanUp() }
        let directory = home.appendingPathComponent("xdg/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.fixture("opencode-auth").write(to: directory.appendingPathComponent("auth.json"))
        let variables = ["XDG_DATA_HOME": home.appendingPathComponent("xdg").path]
        #expect(OpenCodeProvider.credential(in: environment(variables: variables)) == .token("go_FAKEauthJSONkey0000"))
    }

    @Test(arguments: [
        (403, "opencode-entitlement-error", ProviderFetchError.unsupported("No OpenCode Go subscription on this account.")),
        (403, nil, .unauthorized),
        (401, nil, .unauthorized),
        (429, nil, .http(429)),
    ] as [(Int, String?, ProviderFetchError)])
    func mapsHTTPErrors(status: Int, fixture: String?, expected: ProviderFetchError) async throws {
        defer { cleanUp() }
        try installAuthJSON()
        let body = try fixture.map(Self.fixture) ?? Data(#"{"error":{"type":"AuthError"}}"#.utf8)
        OpenCodeStubURLProtocol.reset(status: status, body: body)
        await #expect(throws: expected) {
            try await OpenCodeProvider().fetch(in: environment())
        }
    }

    #if canImport(SQLite3)
    /// The v2 store: OpenCode's `credential` table in `opencode.db`.
    func makeDatabase(_ rows: [(integration: String, active: Bool, value: String)], at url: URL? = nil) throws {
        let url = url ?? dataDirectory.appendingPathComponent("opencode.db")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT, value TEXT,
              connector_id TEXT, method_id TEXT, active INTEGER, time_created INTEGER, time_updated INTEGER);
            """
        for row in rows {
            let value = row.value.replacingOccurrences(of: "'", with: "''")
            sql += "INSERT INTO credential VALUES ('\(UUID().uuidString)', '\(row.integration)', 'fake', '\(value)', NULL, NULL, \(row.active ? 1 : 0), 0, 0);"
        }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func credentialTablePrefersActiveGoKeyOverAuthJSON() async throws {
        defer { cleanUp() }
        try installAuthJSON()
        try makeDatabase([
            ("opencode", true, #"{"type":"key","key":"zen_FAKEgeneral"}"#),
            ("opencode-go", false, #"{"type":"key","key":"go_FAKEinactive"}"#),
            ("opencode-go", true, #"{"type":"key","key":"go_FAKEsqlite"}"#),
        ])
        let database = dataDirectory.appendingPathComponent("opencode.db")
        let before = try Data(contentsOf: database)
        OpenCodeStubURLProtocol.reset(body: try Self.fixture("opencode-usage"))

        _ = try await OpenCodeProvider().fetch(in: environment())
        #expect(OpenCodeStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer go_FAKEsqlite")
        #expect(try Data(contentsOf: database) == before)
    }

    @Test func generalOpenCodeLoginIsUsedWithoutAGoOne() throws {
        defer { cleanUp() }
        let expires = Int((Self.now.timeIntervalSince1970 + 3600) * 1000)
        try makeDatabase([("opencode", true, #"{"type":"oauth","access":"oauth_FAKEaccess","refresh":"r","expires":\#(expires)}"#)])
        #expect(OpenCodeProvider.credential(in: environment()) == .token("oauth_FAKEaccess"))
    }

    @Test func expiredOAuthLoginIsUnauthorizedWithoutARequest() async throws {
        defer { cleanUp() }
        let expired = Int((Self.now.timeIntervalSince1970 - 60) * 1000)
        try makeDatabase([("opencode-go", true, #"{"type":"oauth","access":"oauth_FAKEold","expires":\#(expired)}"#)])
        OpenCodeStubURLProtocol.reset(body: try Self.fixture("opencode-usage"))
        #expect(OpenCodeProvider().isSignedIn(in: environment()))
        await #expect(throws: ProviderFetchError.unauthorized) {
            try await OpenCodeProvider().fetch(in: environment())
        }
        #expect(OpenCodeStubURLProtocol.requests.isEmpty)
    }

    @Test func existingCredentialTableBlocksStaleAuthJSON() throws {
        defer { cleanUp() }
        try installAuthJSON()
        try makeDatabase([("opencode-go", false, #"{"type":"key","key":"go_FAKEloggedOut"}"#)])
        #expect(OpenCodeProvider.credential(in: environment()) == nil)
        #expect(!OpenCodeProvider().isSignedIn(in: environment()))
    }

    @Test func databaseWithoutCredentialTableFallsBackToAuthJSON() throws {
        defer { cleanUp() }
        try installAuthJSON()
        let url = dataDirectory.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE message (id TEXT);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(OpenCodeProvider.credential(in: environment()) == .token("go_FAKEauthJSONkey0000"))
    }

    @Test func honorsOpenCodeDBPath() throws {
        defer { cleanUp() }
        let custom = home.appendingPathComponent("elsewhere/custom.db")
        try makeDatabase([("opencode-go", true, #"{"type":"key","key":"go_FAKEcustom"}"#)], at: custom)
        #expect(OpenCodeProvider.credential(in: environment(variables: ["OPENCODE_DB": custom.path])) == .token("go_FAKEcustom"))
        #expect(OpenCodeProvider.credential(in: environment()) == nil)
    }
    #endif
}
