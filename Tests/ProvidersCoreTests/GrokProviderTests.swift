import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ProvidersCore

/// Answers each request by its path with the stubbed status and body,
/// recording what was asked. One suite uses it at a time (the suite is
/// serialized).
final class GrokStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Billing and settings are asked for concurrently.
        let stub: (status: Int, body: Data) = Self.locked {
            Self.requests.append(request)
            return Self.responses[request.url?.path ?? ""] ?? (404, Data())
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(_ responses: [String: (status: Int, body: Data)] = [:]) {
        locked {
            self.responses = responses
            requests = []
        }
    }

    static var recorded: [URLRequest] { locked { requests } }
}

@Suite(.serialized) struct GrokProviderTests {
    static let now = Date(timeIntervalSince1970: 1_793_869_200) // 2026-11-05T09:00:00Z

    /// A fake home, created on first install and removed by `cleanUp`.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-tests-\(UUID().uuidString)")

    func environment(variables: [String: String] = [:], now: Date = Self.now) -> ProviderEnvironment {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokStubURLProtocol.self]
        return ProviderEnvironment(home: home, session: URLSession(configuration: config),
                                   now: { now }, variables: variables)
    }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func object(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    }

    func installAuth(at relativePath: String = ".grok/auth.json") throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.fixture("grok-auth").write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    static func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }

    // MARK: Mapping

    @Test func mapsWeeklyCreditsAndDetails() throws {
        let snapshot = try GrokProvider.snapshot(from: Self.object("grok-billing"), now: Self.now)
        let weekly = try #require(snapshot.windows.first)
        #expect(snapshot.windows.count == 1)
        #expect(weekly.title == "Weekly")
        #expect(weekly.usedPercent == 12.5)
        // Microsecond timestamps parse (to at least the millisecond).
        let reset = try #require(weekly.resetsAt)
        #expect(abs(reset.timeIntervalSince(Self.utc("2026-11-08T12:00:00.123Z"))) < 0.001)
        #expect(abs((weekly.windowSeconds ?? 0) - 7 * 86400) < 0.001)
        #expect(snapshot.details == [
            ProviderDetail(title: "Grok Build", value: "10%"),
            ProviderDetail(title: "Grok Chat", value: "2.5%"),
            ProviderDetail(title: "On-demand", value: "$2.50 of $10.00", usedPercent: 25),
            ProviderDetail(title: "Balance", value: "$14.46"),
        ])
        #expect(snapshot.plan == nil)
    }

    @Test func omittedPercentInAPeriodIsZero() throws {
        let snapshot = try GrokProvider.snapshot(from: Self.object("grok-billing-period-only"), now: Self.now)
        #expect(snapshot.plan == "SuperGrok")
        #expect(snapshot.windows.map(\.title) == ["Monthly"])
        #expect(snapshot.windows.first?.usedPercent == 0)
        #expect(snapshot.windows.first?.resetsAt == Self.utc("2026-11-20T00:00:00.000Z"))
        #expect(snapshot.details == [ProviderDetail(title: "Balance", value: "$0.00")])
    }

    @Test func productSharesThatDoNotAddUpAreDropped() throws {
        let body: [String: Any] = ["config": [
            "creditUsagePercent": 40,
            "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-11-01T00:00:00Z", "end": "2026-11-08T00:00:00Z"],
            "productUsage": [["product": "GrokBuild", "usagePercent": 10]],
        ]]
        let snapshot = try GrokProvider.snapshot(from: body, now: Self.now)
        #expect(snapshot.windows.first?.usedPercent == 40)
        #expect(snapshot.details.isEmpty)
    }

    @Test func rejectsMalformedBilling() {
        let bodies: [[String: Any]] = [
            [:],
            ["config": [:] as [String: Any]],
            ["config": ["creditUsagePercent": "high", "currentPeriod": ["end": "2026-11-08T00:00:00Z"]]],
        ]
        for body in bodies {
            #expect(throws: ProviderFetchError.invalidResponse) {
                try GrokProvider.snapshot(from: body, now: Self.now)
            }
        }
    }

    // MARK: Credentials and requests

    @Test func missingAuthIsNotSignedIn() async {
        GrokStubURLProtocol.reset()
        #expect(!GrokProvider().isSignedIn(in: environment()))
        await #expect(throws: ProviderFetchError.notSignedIn("No Grok CLI sign-in found. Run `grok login`.")) {
            try await GrokProvider().fetch(in: environment())
        }
        #expect(GrokStubURLProtocol.recorded.isEmpty)
    }

    @Test func prefersTheOIDCEntry() throws {
        defer { cleanUp() }
        try installAuth()
        let credential = try #require(GrokProvider.credential(in: environment()))
        #expect(credential.token == "fake-grok-oidc-access")
        #expect(credential.email == "grok-fake@example.com")
        #expect(credential.displayName == "Fake User")
        #expect(credential.authMode == "oidc")
    }

    @Test func fetchesBillingAndSettingsWithCLIHeaders() async throws {
        defer { cleanUp() }
        try installAuth()
        GrokStubURLProtocol.reset([
            "/v1/billing": (200, try Self.fixture("grok-billing")),
            "/v1/settings": (200, try Self.fixture("grok-settings")),
        ])
        #expect(GrokProvider().isSignedIn(in: environment()))

        let snapshot = try await GrokProvider().fetch(in: environment())
        #expect(snapshot.account == "grok-fake@example.com")
        #expect(snapshot.plan == "SuperGrok Heavy")
        #expect(snapshot.windows.first?.title == "Weekly")
        let requests = GrokStubURLProtocol.recorded
        #expect(Set(requests.compactMap(\.url?.absoluteString)) == [
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            "https://cli-chat-proxy.grok.com/v1/settings",
        ])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-grok-oidc-access")
            #expect(request.value(forHTTPHeaderField: "X-XAI-Token-Auth") == "xai-grok-cli")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        }
    }

    @Test func failedSettingsFallBackToTheLoginPlan() async throws {
        defer { cleanUp() }
        try installAuth()
        GrokStubURLProtocol.reset([
            "/v1/billing": (200, try Self.fixture("grok-billing")),
            "/v1/settings": (500, Data()),
        ])
        let snapshot = try await GrokProvider().fetch(in: environment())
        #expect(snapshot.plan == "SuperGrok")
    }

    @Test func honorsGrokHome() throws {
        defer { cleanUp() }
        try installAuth(at: "custom-grok/auth.json")
        let variables = ["GROK_HOME": home.appendingPathComponent("custom-grok").path]
        #expect(GrokProvider().isSignedIn(in: environment(variables: variables)))
        #expect(!GrokProvider().isSignedIn(in: environment()))
    }

    @Test func expiredTokenIsUnauthorizedWithoutARequest() async throws {
        defer { cleanUp() }
        try installAuth()
        GrokStubURLProtocol.reset(["/v1/billing": (200, try Self.fixture("grok-billing"))])
        let later = Self.utc("2026-11-11T00:00:00.000Z")
        await #expect(throws: ProviderFetchError.unauthorized) {
            try await GrokProvider().fetch(in: environment(now: later))
        }
        #expect(GrokStubURLProtocol.recorded.isEmpty)
    }

    @Test(arguments: [
        (412, ProviderFetchError.unsupported("Grok team accounts have no personal quota.")),
        (401, .unauthorized),
        (403, .unauthorized),
        (502, .http(502)),
    ])
    func mapsHTTPErrors(status: Int, expected: ProviderFetchError) async throws {
        defer { cleanUp() }
        try installAuth()
        GrokStubURLProtocol.reset([
            "/v1/billing": (status, try Self.fixture("grok-team-error")),
            "/v1/settings": (200, try Self.fixture("grok-settings")),
        ])
        await #expect(throws: expected) {
            try await GrokProvider().fetch(in: environment())
        }
    }
}
