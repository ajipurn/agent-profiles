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
/// was asked (and the request body, which URLSession turns into a stream).
/// One suite uses it at a time (the suite is serialized).
final class KiroStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (200, Data())
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append((request, request.httpBody ?? Self.read(request.httpBodyStream)))
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/x-amz-json-1.0"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(status: Int = 200, body: Data = Data()) {
        response = (status, body)
        requests = []
    }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
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

@Suite(.serialized) struct KiroProviderTests {
    static let now = Date(timeIntervalSince1970: 1_793_869_200) // 2026-11-05T09:00:00Z
    static let arn = "arn:aws:codewhisperer:us-east-1:123456789012:profile/FAKEPROFILE"

    /// A fake home, created on first install and removed by `cleanUp`.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("kiro-tests-\(UUID().uuidString)")
    var dataDirectory: URL { home.appendingPathComponent("kiro-data") }
    var variables: [String: String] { ["KIRO_DATA_DIR": dataDirectory.path] }

    func environment(variables: [String: String]? = nil) -> ProviderEnvironment {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KiroStubURLProtocol.self]
        return ProviderEnvironment(home: home, session: URLSession(configuration: config),
                                   now: { Self.now }, variables: variables ?? self.variables)
    }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func object(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    // MARK: Mapping

    @Test func splitsPlanFromOverageWithoutDoubleCounting() throws {
        let snapshot = try KiroProvider.snapshot(from: Self.object("kiro-usage-limits"), fetchedAt: Self.now)
        #expect(snapshot.plan == "Power")
        #expect(snapshot.account == nil)
        #expect(snapshot.windows.map(\.title) == ["Credits", "Overage"])
        // currentUsage (13603.49) includes overage (3603.49): the plan is full, not 136%.
        #expect(snapshot.windows[0].usedPercent == 100)
        #expect(abs(snapshot.windows[1].usedPercent - 36.0349) < 0.0001)
        let reset = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01
        #expect(snapshot.windows.allSatisfy { $0.resetsAt == reset && $0.windowSeconds == 31 * 86400 })
        #expect(snapshot.details.count == 2)
        #expect(snapshot.details[0] == ProviderDetail(title: "Credits", value: "10000 / 10000"))
        #expect(snapshot.details[1].title == "Overage charges")
        #expect(snapshot.details[1].value == "$144.14 of $400.00")
        #expect(abs((snapshot.details[1].usedPercent ?? 0) - 36.035) < 0.001)
    }

    @Test func freePlanHasOnlyCredits() throws {
        let snapshot = try KiroProvider.snapshot(from: Self.object("kiro-usage-limits-free"), fetchedAt: Self.now)
        #expect(snapshot.plan == "Free")
        #expect(snapshot.windows.map(\.title) == ["Credits"])
        #expect(snapshot.windows[0].usedPercent == 25)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_764_950_400))
        #expect(snapshot.details == [ProviderDetail(title: "Credits", value: "12.50 / 50")])
    }

    @Test func bonusCreditsKeepThePlanGaugeOut() throws {
        let snapshot = try KiroProvider.snapshot(from: Self.object("kiro-usage-limits-bonus"), fetchedAt: Self.now)
        #expect(snapshot.plan == "Pro+")
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.details == [ProviderDetail(title: "Credits used", value: "2100.25 incl. bonus")])
    }

    @Test func rejectsAmbiguousOrImpossibleCredit() throws {
        let several: [String: Any] = ["usageBreakdownList": [
            ["resourceType": "CREDIT", "currentUsageWithPrecision": 1.0, "usageLimitWithPrecision": 10.0],
            ["resourceType": "CREDIT", "currentUsageWithPrecision": 2.0, "usageLimitWithPrecision": 20.0],
        ]]
        let overageAboveTotal: [String: Any] = ["usageBreakdownList": [
            ["resourceType": "CREDIT", "currentUsageWithPrecision": 1.0, "usageLimitWithPrecision": 10.0,
             "currentOveragesWithPrecision": 5.0],
        ]]
        for body in [several, overageAboveTotal, [:]] {
            #expect(throws: ProviderFetchError.invalidResponse) {
                try KiroProvider.snapshot(from: body, fetchedAt: Self.now)
            }
        }
    }

    @Test func endpointFollowsProfileRegionOnly() {
        #expect(KiroProvider.endpoint(forProfileARN: Self.arn)?.absoluteString == "https://codewhisperer.us-east-1.amazonaws.com/")
        #expect(KiroProvider.endpoint(forProfileARN: "arn:aws:codewhisperer:eu-central-1:1:profile/x")?.absoluteString
            == "https://q.eu-central-1.amazonaws.com/")
        for arn in ["", "not-an-arn", "arn:aws:codewhisperer:ap-southeast-1:1:profile/x",
                    "arn:aws:s3:us-east-1:1:profile/x", "arn:aws:codewhisperer:us-east-1:1:profile/",
                    "arn:aws:codewhisperer:us-east-1:1:profile/x "] {
            #expect(KiroProvider.endpoint(forProfileARN: arn) == nil)
        }
    }

    // MARK: Credentials and requests

    @Test func missingDatabaseIsNotSignedIn() async {
        KiroStubURLProtocol.reset()
        #expect(!KiroProvider().isSignedIn(in: environment()))
        do {
            _ = try await KiroProvider().fetch(in: environment())
            Issue.record("fetch succeeded without a sign-in")
        } catch {
            guard case .notSignedIn? = error as? ProviderFetchError else { Issue.record("unexpected \(error)"); return }
        }
        #expect(KiroStubURLProtocol.requests.isEmpty)
    }

    #if canImport(SQLite3)
    /// The kiro-cli state database, as the CLI lays it out.
    @discardableResult
    func makeDatabase(token: String? = "kiro_FAKEaccess", arn: String = Self.arn, at url: URL? = nil) throws -> URL {
        let url = url ?? dataDirectory.appendingPathComponent("data.sqlite3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE auth_kv(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO state VALUES ('api.codewhisperer.profile', '{"arn":"\(arn)","profile_name":"fake"}');
            """
        if let token {
            sql += """
                INSERT INTO auth_kv VALUES ('kirocli:odic:token',
                  '{"access_token":"\(token)","refresh_token":"kiro_FAKErefresh","expires_at":"2026-11-05T10:00:00Z","region":"us-east-1"}');
                """
        }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func fetchesGetUsageLimitsWithCLIToken() async throws {
        defer { cleanUp() }
        let database = try makeDatabase()
        let before = try Data(contentsOf: database)
        KiroStubURLProtocol.reset(body: try Self.fixture("kiro-usage-limits"))
        #expect(KiroProvider().isSignedIn(in: environment()))

        let snapshot = try await KiroProvider().fetch(in: environment())
        #expect(snapshot.windows.first?.usedPercent == 100)
        let (request, body) = try #require(KiroStubURLProtocol.requests.first)
        #expect(KiroStubURLProtocol.requests.count == 1)
        #expect(request.url?.absoluteString == "https://codewhisperer.us-east-1.amazonaws.com/")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer kiro_FAKEaccess")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == "AmazonCodeWhispererService.GetUsageLimits")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.0")
        let json = try JSONSerialization.jsonObject(with: #require(body)) as? [String: String]
        #expect(json == ["profileArn": Self.arn])
        #expect(try Data(contentsOf: database) == before)
    }

    @Test func databaseWithoutTokenIsNotSignedIn() async throws {
        defer { cleanUp() }
        try makeDatabase(token: nil)
        #expect(!KiroProvider().isSignedIn(in: environment()))
        await #expect(throws: ProviderFetchError.notSignedIn("No Kiro CLI sign-in found. Run `kiro-cli login`.")) {
            try await KiroProvider().fetch(in: environment())
        }
    }

    @Test func unsupportedRegionSendsNothing() async throws {
        defer { cleanUp() }
        try makeDatabase(arn: "arn:aws:codewhisperer:ap-southeast-1:123456789012:profile/FAKE")
        KiroStubURLProtocol.reset(body: try Self.fixture("kiro-usage-limits"))
        do {
            _ = try await KiroProvider().fetch(in: environment())
            Issue.record("fetch succeeded for an unsupported region")
        } catch {
            guard case .unsupported? = error as? ProviderFetchError else { Issue.record("unexpected \(error)"); return }
        }
        #expect(KiroStubURLProtocol.requests.isEmpty)
    }

    @Test(arguments: [(403, ProviderFetchError.unauthorized), (401, .unauthorized), (400, .http(400))])
    func mapsHTTPErrors(status: Int, expected: ProviderFetchError) async throws {
        defer { cleanUp() }
        try makeDatabase()
        KiroStubURLProtocol.reset(status: status, body: Data(#"{"__type":"AccessDeniedException","message":"expired"}"#.utf8))
        await #expect(throws: expected) {
            try await KiroProvider().fetch(in: environment())
        }
    }

    #if os(macOS)
    @Test func defaultsToApplicationSupportOnMacOS() throws {
        defer { cleanUp() }
        try makeDatabase(at: home.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3"))
        #expect(KiroProvider().isSignedIn(in: environment(variables: [:])))
        #expect(try KiroProvider.identity(in: environment(variables: [:])).accessToken == "kiro_FAKEaccess")
    }
    #endif
    #endif
}
