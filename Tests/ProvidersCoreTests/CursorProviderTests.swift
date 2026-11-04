import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
@testable import ProvidersCore

// MARK: - HTTP stub

private final class CursorStubState: @unchecked Sendable {
    struct Recorded {
        var request: URLRequest
        var body: Data
    }

    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Data)
    private let lock = NSLock()
    private var handler: Handler?
    private var recorded: [Recorded] = []

    func reset(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        recorded = []
    }

    func respond(to request: URLRequest, body: Data) -> (Int, Data) {
        lock.lock()
        recorded.append(Recorded(request: request, body: body))
        let handler = self.handler
        lock.unlock()
        return handler?(request, body) ?? (404, Data())
    }

    var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

private final class CursorStubURLProtocol: URLProtocol {
    static let state = CursorStubState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.state.respond(to: request, body: Self.body(of: request))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Helpers

private enum CursorFixtures {
    /// 2026-11-05T12:00:00Z, the clock the fixture tokens' `exp` claims are written against.
    static let now = Date(timeIntervalSince1970: 1_793_880_000)

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func token(_ key: String) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data("cursor-tokens")) as? [String: String]
        return try #require(json?[key])
    }

    static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}

private struct CursorSandbox {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-provider-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    func environment() -> ProviderEnvironment {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorStubURLProtocol.self]
        return ProviderEnvironment(
            home: home,
            session: URLSession(configuration: configuration),
            now: { CursorFixtures.now },
            variables: [:])
    }

    var databaseURL: URL { CursorProvider.stateDatabaseURL(environment()) }

    func writeAgentAuth() throws {
        let url = home.appendingPathComponent(".config/cursor/auth.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CursorFixtures.data("cursor-agent-auth").write(to: url)
    }

    #if canImport(SQLite3)
    /// A VS Code-style `state.vscdb` holding `cursorAuth/accessToken` as text or a blob.
    func writeDatabase(token: String, asUTF16Blob: Bool = false, wal: Bool = false) throws {
        let url = databaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        if wal { try #require(sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK) }
        try #require(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)",
                                  nil, nil, nil) == SQLITE_OK)
        try #require(sqlite3_exec(db, "INSERT INTO ItemTable VALUES ('cursorAuth/cachedEmail', 'other@example.com')",
                                  nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?)", -1,
                                        &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if asUTF16Blob {
            let blob = try #require(token.data(using: .utf16LittleEndian))
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(blob.count), transient) }
        } else {
            sqlite3_bind_text(statement, 1, token, -1, transient)
        }
        try #require(sqlite3_step(statement) == SQLITE_DONE)
        if wal { try #require(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK) }
    }
    #endif
}

private typealias CursorResponse = (status: Int, fixture: String)

/// Routes cursor.com's endpoints to fixtures; anything else is a 404.
private func cursorRoutes(
    summary: CursorResponse = (200, "cursor-usage-summary"),
    me: CursorResponse = (200, "cursor-auth-me"),
    usage: CursorResponse = (200, "cursor-usage-token-plan"),
    sand: CursorResponse = (200, "cursor-sand-usage"),
    refuseCookieContaining refused: String? = nil
) throws -> CursorStubState.Handler {
    let bodies = try [summary, me, usage, sand].map { try CursorFixtures.data($0.fixture) }
    return { request, _ in
        if let refused, request.value(forHTTPHeaderField: "Cookie")?.contains(refused) == true {
            return (401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        switch request.url?.path {
        case "/api/usage-summary": return (summary.status, bodies[0])
        case "/api/auth/me": return (me.status, bodies[1])
        case "/api/usage": return (usage.status, bodies[2])
        case "/api/dashboard/get-sand-usage-status": return (sand.status, bodies[3])
        default: return (404, Data())
        }
    }
}

// MARK: - Tests

@Suite(.serialized) struct CursorProviderTests {
    #if canImport(SQLite3)
    @Test func mapsAProPlanFromTheAppSession() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        let token = try CursorFixtures.token("app")
        try sandbox.writeDatabase(token: token)
        CursorStubURLProtocol.state.reset(try cursorRoutes())

        let snapshot = try await CursorProvider().fetch(in: sandbox.environment())

        #expect(snapshot.account == "cursor.user@example.com")
        #expect(snapshot.plan == "Pro")
        #expect(snapshot.windows.map(\.title) == ["Monthly", "Auto", "API", "Grok Bot"])
        #expect(snapshot.windows.map(\.usedPercent) == [75, 42.5, 12.25, 33])
        #expect(snapshot.windows[0].resetsAt == CursorFixtures.date("2026-11-20T00:00:00Z"))
        #expect(snapshot.windows[0].windowSeconds == TimeInterval(31 * 86_400))
        #expect(snapshot.windows[3].resetsAt == CursorFixtures.date("2026-11-10T00:00:00Z"))
        #expect(snapshot.windows[3].windowSeconds == TimeInterval(7 * 86_400))
        #expect(snapshot.details == [
            ProviderDetail(title: "Included", value: "$15.00 of $20.00", usedPercent: 75),
            ProviderDetail(title: "On-demand", value: "$5.00 of $100.00", usedPercent: 5),
        ])

        let requests = CursorStubURLProtocol.state.requests
        #expect(Set(requests.compactMap { $0.request.url?.path }) == [
            "/api/usage-summary", "/api/auth/me", "/api/dashboard/get-sand-usage-status", "/api/usage",
        ])
        #expect(requests.allSatisfy {
            $0.request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=user_01FAKECURSOR%3A%3A\(token)"
        })
        let sand = try #require(requests.first { $0.request.url?.path == "/api/dashboard/get-sand-usage-status" })
        #expect(sand.request.httpMethod == "POST")
        #expect(sand.request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
        let usage = try #require(requests.first { $0.request.url?.path == "/api/usage" })
        #expect(usage.request.url?.query == "user=user_01FAKECURSOR")
    }

    @Test func legacyRequestQuotaLeads() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        try sandbox.writeDatabase(token: CursorFixtures.token("app"))
        CursorStubURLProtocol.state.reset(try cursorRoutes(usage: (200, "cursor-usage-legacy")))

        let snapshot = try await CursorProvider().fetch(in: sandbox.environment())

        #expect(snapshot.windows.map(\.title) == ["Requests"])
        #expect(snapshot.windows.first?.usedPercent == 25)
        #expect(snapshot.details.first == ProviderDetail(title: "Requests", value: "125 of 500", usedPercent: 25))
        #expect(!snapshot.details.contains { $0.title == "Included" })
    }

    @Test func unifiedAccountsShowTheSharedWeeklyPool() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        try sandbox.writeDatabase(token: CursorFixtures.token("app"))
        CursorStubURLProtocol.state.reset(try cursorRoutes(
            summary: (200, "cursor-usage-summary-unified"), sand: (200, "cursor-sand-unified")))

        let snapshot = try await CursorProvider().fetch(in: sandbox.environment())

        #expect(snapshot.plan == "Pro")
        #expect(snapshot.windows == [ProviderWindow(
            title: "Weekly", usedPercent: 64, resetsAt: CursorFixtures.date("2026-11-10T00:00:00Z"),
            windowSeconds: 7 * 86_400)])
        // Unified billing has no legacy request quota to look up.
        #expect(!CursorStubURLProtocol.state.requests.contains { $0.request.url?.path == "/api/usage" })
    }

    @Test func teamPlansUseThePooledBudget() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        try sandbox.writeDatabase(token: CursorFixtures.token("app"))
        CursorStubURLProtocol.state.reset(try cursorRoutes(
            summary: (200, "cursor-usage-summary-team"), sand: (200, "cursor-sand-none")))

        let snapshot = try await CursorProvider().fetch(in: sandbox.environment())

        #expect(snapshot.plan == "Enterprise")
        #expect(snapshot.windows.map(\.title) == ["Monthly"])
        #expect(snapshot.windows.first?.usedPercent == 30)
        #expect(snapshot.details == [
            ProviderDetail(title: "Team on-demand", value: "$20.00 of $500.00", usedPercent: 4),
            ProviderDetail(title: "On-demand", value: "$3.50"),
        ])
    }

    @Test func readsUTF16BlobTokens() throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        let token = try CursorFixtures.token("app")
        try sandbox.writeDatabase(token: token, asUTF16Blob: true)

        #expect(CursorProvider.storedTokens(in: sandbox.environment()) == [token])
    }

    @Test func readsAnIdleWALDatabaseWithoutCreatingSidecars() throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        let token = try CursorFixtures.token("app")
        try sandbox.writeDatabase(token: token, wal: true)
        // What a cleanly closed Cursor leaves behind: WAL mode in the header, no sidecars.
        // (Darwin's SQLite keeps empty sidecars on close, so drop them here.)
        let path = sandbox.databaseURL.path
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")

        #expect(CursorProvider().isSignedIn(in: sandbox.environment()))
        #expect(CursorProvider.storedTokens(in: sandbox.environment()) == [token])
        #expect(!FileManager.default.fileExists(atPath: path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: path + "-shm"))
    }

    @Test func refusedAppSessionFallsBackToCursorAgent() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        try sandbox.writeDatabase(token: CursorFixtures.token("app"))
        try sandbox.writeAgentAuth()
        CursorStubURLProtocol.state.reset(try cursorRoutes(refuseCookieContaining: "user_01FAKECURSOR"))

        let snapshot = try await CursorProvider().fetch(in: sandbox.environment())

        #expect(snapshot.windows.first?.title == "Monthly")
        let last = try #require(CursorStubURLProtocol.state.requests.last)
        #expect(last.request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=user_01FAKEAGENT%3A%3A") == true)
    }

    @Test func keychainEncryptedTokenIsUnsupported() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        try sandbox.writeDatabase(token: CursorFixtures.token("encrypted"))
        CursorStubURLProtocol.state.reset(try cursorRoutes())

        do {
            _ = try await CursorProvider().fetch(in: sandbox.environment())
            Issue.record("Expected unsupported")
        } catch ProviderFetchError.unsupported(let message) {
            #expect(message.contains("Keychain"))
        }
        #expect(CursorStubURLProtocol.state.requests.isEmpty)
    }

    @Test func expiredAppTokenIsUnauthorizedWithoutARequest() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        try sandbox.writeDatabase(token: CursorFixtures.token("expired"))
        CursorStubURLProtocol.state.reset(try cursorRoutes())

        await #expect(throws: ProviderFetchError.unauthorized) {
            _ = try await CursorProvider().fetch(in: sandbox.environment())
        }
        #expect(CursorStubURLProtocol.state.requests.isEmpty)
    }
    #endif

    @Test func cursorAgentLoginWorksWithoutTheApp() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        try sandbox.writeAgentAuth()
        CursorStubURLProtocol.state.reset(try cursorRoutes())

        let snapshot = try await CursorProvider().fetch(in: sandbox.environment())

        #expect(snapshot.plan == "Pro")
        let summary = try #require(CursorStubURLProtocol.state.requests.first { $0.request.url?.path == "/api/usage-summary" })
        #expect(summary.request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=user_01FAKEAGENT%3A%3A") == true)
    }

    @Test func missingSignInIsNotSignedIn() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        CursorStubURLProtocol.state.reset(try cursorRoutes())

        #expect(!CursorProvider().isSignedIn(in: sandbox.environment()))
        do {
            _ = try await CursorProvider().fetch(in: sandbox.environment())
            Issue.record("Expected notSignedIn")
        } catch ProviderFetchError.notSignedIn(let hint) {
            #expect(hint.contains("Cursor"))
        }
    }

    @Test func usageSummaryErrorsMapAndOptionalReadsDoNot() async throws {
        let sandbox = try CursorSandbox()
        defer { sandbox.remove() }
        try sandbox.writeAgentAuth()

        CursorStubURLProtocol.state.reset(try cursorRoutes(summary: (401, "cursor-auth-me")))
        await #expect(throws: ProviderFetchError.unauthorized) {
            _ = try await CursorProvider().fetch(in: sandbox.environment())
        }
        CursorStubURLProtocol.state.reset(try cursorRoutes(summary: (500, "cursor-auth-me")))
        await #expect(throws: ProviderFetchError.http(500)) {
            _ = try await CursorProvider().fetch(in: sandbox.environment())
        }

        CursorStubURLProtocol.state.reset(try cursorRoutes(
            me: (500, "cursor-auth-me"), usage: (500, "cursor-auth-me"), sand: (404, "cursor-auth-me")))
        let snapshot = try await CursorProvider().fetch(in: sandbox.environment())
        #expect(snapshot.account == nil)
        #expect(snapshot.windows.map(\.title) == ["Monthly", "Auto", "API"])
    }

    @Test func plansAndGrokBotAllowances() {
        #expect(CursorProvider.planName("pro_plus") == "Pro+")
        #expect(CursorProvider.planName("free_trial") == "Pro Trial")
        #expect(CursorProvider.planName("unified_ultra") == "Ultra")
        #expect(CursorProvider.planName("new_tier") == "New Tier")
        #expect(CursorProvider.planName(nil) == nil)

        let now = CursorFixtures.now
        let trial = CursorProvider.grokBotWindow([
            "usagePercent": 100, "includedLimitZero": true, "sandTrialExpiresAt": "2026-11-12T00:00:00Z",
            "nextResetTimestampUtc": "2026-11-10T00:00:00Z",
        ], now: now)
        // A trial's expiry is not a reset.
        #expect(trial == ProviderWindow(title: "Grok Bot", usedPercent: 100))
        #expect(CursorProvider.grokBotWindow(["usagePercent": 10, "includedLimitZero": true], now: now) == nil)
        #expect(CursorProvider.grokBotWindow(
            ["usagePercent": 10, "hasNonZeroIncludedLimit": true, "usesPooledEnterpriseAllowance": true], now: now) == nil)
    }
}
