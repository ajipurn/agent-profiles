import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ProvidersCore

// MARK: - HTTP stub

private final class AntigravityStubState: @unchecked Sendable {
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

private final class AntigravityStubURLProtocol: URLProtocol {
    static let state = AntigravityStubState()

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

private enum AntigravityFixtures {
    /// 2026-11-05T12:00:00Z, the clock the fixtures' expiry dates are written against.
    static let now = Date(timeIntervalSince1970: 1_793_880_000)
    /// The `aud` of the fixtures' ID token.
    static let clientID = "42-fake-antigravity-client.apps.googleusercontent.com"

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func object(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    static func form(_ data: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }

    static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}

private struct AntigravitySandbox {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-provider-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    var tokenURL: URL { home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token") }

    /// The token fixture, with the refresh token replaced so each test has its own renewal.
    func writeToken(_ fixture: String, refreshToken: String? = nil) throws {
        var json = AntigravityFixtures.object(try AntigravityFixtures.data(fixture))
        if let refreshToken, var token = json["token"] as? [String: Any] {
            token["refresh_token"] = refreshToken
            json["token"] = token
        }
        try FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: tokenURL)
    }

    func environment(_ variables: [String: String] = [:]) -> ProviderEnvironment {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AntigravityStubURLProtocol.self]
        return ProviderEnvironment(
            home: home,
            session: URLSession(configuration: configuration),
            now: { AntigravityFixtures.now },
            variables: variables)
    }
}

/// A provider that never scans installed apps outside the sandbox.
private func sandboxedProvider(artifacts: [URL] = []) -> AntigravityProvider {
    var provider = AntigravityProvider()
    provider.artifactSearchPaths = artifacts
    return provider
}

private typealias AntigravityResponse = (status: Int, fixture: String)

/// Routes Google's endpoints to fixtures; anything else is a 404.
private func antigravityRoutes(
    loadCodeAssist: AntigravityResponse = (200, "antigravity-load-code-assist"),
    summary: AntigravityResponse = (200, "antigravity-quota-summary"),
    dailySummary: AntigravityResponse = (200, "antigravity-quota-summary-daily"),
    refresh: AntigravityResponse = (200, "antigravity-token-refresh")
) throws -> AntigravityStubState.Handler {
    let bodies = try [loadCodeAssist, summary, dailySummary, refresh, (200, "antigravity-userinfo")]
        .map { try AntigravityFixtures.data($0.fixture) }
    return { request, _ in
        switch (request.url?.host, request.url?.path) {
        case ("oauth2.googleapis.com", "/token"): return (refresh.status, bodies[3])
        case ("www.googleapis.com", "/oauth2/v2/userinfo"): return (200, bodies[4])
        case (_, "/v1internal:loadCodeAssist"): return (loadCodeAssist.status, bodies[0])
        case ("cloudcode-pa.googleapis.com", "/v1internal:retrieveUserQuotaSummary"): return (summary.status, bodies[1])
        case ("daily-cloudcode-pa.googleapis.com", "/v1internal:retrieveUserQuotaSummary"):
            return (dailySummary.status, bodies[2])
        default: return (404, Data())
        }
    }
}

private func expectUnsupported(_ provider: AntigravityProvider, _ environment: ProviderEnvironment,
                               containing text: String) async {
    do {
        _ = try await provider.fetch(in: environment)
        Issue.record("Expected an unsupported error")
    } catch ProviderFetchError.unsupported(let message) {
        #expect(message.contains(text), "\(message)")
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

// MARK: - Tests

@Suite(.serialized) struct AntigravityProviderTests {
    @Test func mapsTheQuotaSummaryPools() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token")
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes())

        let snapshot = try await sandboxedProvider().fetch(in: sandbox.environment())

        #expect(snapshot.account == "agy.user@example.com")
        #expect(snapshot.plan == "Pro")
        #expect(snapshot.windows.map(\.title) == [
            "Gemini 5h", "Gemini weekly", "Argon weekly", "Claude/GPT 5h", "Claude/GPT weekly",
        ])
        #expect(snapshot.windows.map { $0.usedPercent.rounded() } == [5, 14, 40, 0, 11])
        #expect(snapshot.windows.map(\.windowSeconds) == [18_000, 604_800, 604_800, 18_000, 604_800])
        #expect(snapshot.windows[0].resetsAt == AntigravityFixtures.date("2026-11-05T15:48:04Z"))

        let requests = AntigravityStubURLProtocol.state.requests
        // A complete production summary needs no daily read.
        #expect(requests.map { $0.request.url?.absoluteString } == [
            "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        ])
        for recorded in requests {
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.fake-antigravity-access-token")
            #expect(recorded.request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("antigravity/") == true)
        }
        let metadata = AntigravityFixtures.object(requests[0].body)["metadata"] as? [String: Any]
        #expect(metadata?["ideType"] as? String == "ANTIGRAVITY")
        #expect(AntigravityFixtures.object(requests[1].body)["project"] as? String == "fake-antigravity-project-789")
    }

    @Test func dailyHostFillsPoolsProductionLeftOut() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token")
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes(
            loadCodeAssist: (200, "antigravity-load-code-assist-free"),
            summary: (200, "antigravity-quota-summary-partial")))

        let snapshot = try await sandboxedProvider().fetch(in: sandbox.environment())

        #expect(snapshot.windows.map(\.title) == ["Gemini 5h", "Gemini weekly", "Claude/GPT 5h", "Claude/GPT weekly"])
        // Production wins where it measured a pool; daily supplies the Gemini pools.
        #expect(snapshot.windows.map { $0.usedPercent.rounded() } == [20, 30, 75, 50])
        // A measured 5-hour pool contradicts a "Free" label.
        #expect(snapshot.plan == nil)
        let quotaRequest = try #require(AntigravityStubURLProtocol.state.requests.last)
        #expect(quotaRequest.request.url?.host == "daily-cloudcode-pa.googleapis.com")
        #expect(AntigravityFixtures.object(quotaRequest.body)["project"] as? String == "fake-antigravity-free-project")
    }

    @Test func missingTokenFileIsNotSignedIn() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes())
        let provider = sandboxedProvider()

        #expect(!provider.isSignedIn(in: sandbox.environment()))
        do {
            _ = try await provider.fetch(in: sandbox.environment())
            Issue.record("Expected notSignedIn")
        } catch ProviderFetchError.notSignedIn(let hint) {
            #expect(hint.contains("agy"))
        }
        #expect(AntigravityStubURLProtocol.state.requests.isEmpty)

        try sandbox.writeToken("antigravity-oauth-token")
        #expect(provider.isSignedIn(in: sandbox.environment()))
    }

    @Test func expiredTokenIsRenewedInMemoryOnly() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token-expired")
        let original = try Data(contentsOf: sandbox.tokenURL)
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes())
        let environment = sandbox.environment([
            "ANTIGRAVITY_OAUTH_CLIENT_ID": "fake-env-client.apps.googleusercontent.com",
            "ANTIGRAVITY_OAUTH_CLIENT_SECRET": "fake-env-secret",
        ])

        let snapshot = try await sandboxedProvider().fetch(in: environment)

        #expect(snapshot.windows.count == 5)
        let requests = AntigravityStubURLProtocol.state.requests
        #expect(requests.first?.request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(AntigravityFixtures.form(requests[0].body) == [
            "client_id": "fake-env-client.apps.googleusercontent.com",
            "client_secret": "fake-env-secret",
            "refresh_token": "1//fake-antigravity-refresh-token-expired",
            "grant_type": "refresh_token",
        ])
        #expect(requests.dropFirst().allSatisfy {
            $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.fake-antigravity-renewed-token"
        })
        #expect(try Data(contentsOf: sandbox.tokenURL) == original, "the token file must not be rewritten")
    }

    @Test func renewsWithTheClientFoundInTheInstalledBinary() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token-expired", refreshToken: "1//fake-antigravity-refresh-artifact")
        // Go string pools run constants together; the scan must still find one pair.
        var binary = Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])
        binary.append(Data("runtime.mainhttps://oauth2.googleapis.com/token\(AntigravityFixtures.clientID)".utf8))
        binary.append(Data(("GOCSPX-" + "FakeAgySecret_0123456789abcdABCnext.string").utf8))
        let artifact = sandbox.home.appendingPathComponent("fake-agy")
        try binary.write(to: artifact)
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes())

        _ = try await sandboxedProvider(artifacts: [artifact]).fetch(in: sandbox.environment())

        let form = AntigravityFixtures.form(try #require(AntigravityStubURLProtocol.state.requests.first).body)
        #expect(form["client_id"] == AntigravityFixtures.clientID)
        #expect(form["client_secret"] == ("GOCSPX-" + "FakeAgySecret_0123456789abcd"))
    }

    @Test func ambiguousArtifactsAreNotUsed() {
        var twoSecrets = Data("1-a.apps.googleusercontent.com".utf8)
        twoSecrets.append(Data(("GOCSPX-" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaa GOCSPX-" + "bbbbbbbbbbbbbbbbbbbbbbbbbbbb").utf8))
        #expect(AntigravityProvider.client(inArtifact: twoSecrets, audience: nil) == nil)

        var twoIDs = Data("1-a.apps.googleusercontent.com 2-b.apps.googleusercontent.com".utf8)
        twoIDs.append(Data((" GOCSPX-" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaa").utf8))
        #expect(AntigravityProvider.client(inArtifact: twoIDs, audience: nil) == nil)
        #expect(AntigravityProvider.client(inArtifact: twoIDs, audience: "2-b.apps.googleusercontent.com")
            == AntigravityProvider.OAuthClient(id: "2-b.apps.googleusercontent.com",
                                               secret: ("GOCSPX-" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
        #expect(AntigravityProvider.client(inArtifact: twoIDs, audience: "3-c.apps.googleusercontent.com") == nil)
    }

    @Test func expiredTokenWithoutAClientExplainsHowToRenew() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token-expired", refreshToken: "1//fake-antigravity-refresh-no-client")
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes())

        do {
            _ = try await sandboxedProvider().fetch(in: sandbox.environment())
            Issue.record("Expected notSignedIn")
        } catch ProviderFetchError.notSignedIn(let hint) {
            #expect(hint.contains("agy"))
        }
        #expect(AntigravityStubURLProtocol.state.requests.isEmpty)
    }

    @Test func refusedRefreshIsUnauthorized() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token-expired", refreshToken: "1//fake-antigravity-refresh-revoked")
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes(refresh: (400, "antigravity-userinfo")))
        let environment = sandbox.environment(["ANTIGRAVITY_OAUTH_CLIENT_ID": "id", "ANTIGRAVITY_OAUTH_CLIENT_SECRET": "s"])

        await #expect(throws: ProviderFetchError.unauthorized) {
            _ = try await sandboxedProvider().fetch(in: environment)
        }
    }

    @Test func subscriptionRequiredOnBothHostsIsUnsupported() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token")
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes(
            summary: (403, "antigravity-subscription-required"),
            dailySummary: (403, "antigravity-subscription-required")))

        await expectUnsupported(sandboxedProvider(), sandbox.environment(), containing: "subscription")
    }

    @Test func refusedTokenIsUnauthorized() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token")

        AntigravityStubURLProtocol.state.reset(try antigravityRoutes(loadCodeAssist: (401, "antigravity-userinfo")))
        await #expect(throws: ProviderFetchError.unauthorized) {
            _ = try await sandboxedProvider().fetch(in: sandbox.environment())
        }
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes(
            summary: (401, "antigravity-userinfo"), dailySummary: (401, "antigravity-userinfo")))
        await #expect(throws: ProviderFetchError.unauthorized) {
            _ = try await sandboxedProvider().fetch(in: sandbox.environment())
        }
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes(
            summary: (500, "antigravity-userinfo"), dailySummary: (503, "antigravity-userinfo")))
        await #expect(throws: ProviderFetchError.http(500)) {
            _ = try await sandboxedProvider().fetch(in: sandbox.environment())
        }
    }

    @Test func clientRejectedByCloudCodeIsUnsupported() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token")
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes(
            loadCodeAssist: (200, "antigravity-load-code-assist-rejected")))

        await expectUnsupported(sandboxedProvider(), sandbox.environment(), containing: "Sign in to `agy` again")
    }

    @Test func unmeasuredSummaryIsUnsupported() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        try sandbox.writeToken("antigravity-oauth-token")
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes(
            summary: (200, "antigravity-userinfo"), dailySummary: (200, "antigravity-userinfo")))

        await expectUnsupported(sandboxedProvider(), sandbox.environment(), containing: "no quota")
    }

    @Test func accountFallsBackToUserInfoWithoutAnIDToken() async throws {
        let sandbox = try AntigravitySandbox()
        defer { sandbox.remove() }
        var json = AntigravityFixtures.object(try AntigravityFixtures.data("antigravity-oauth-token"))
        json["id_token"] = nil
        try FileManager.default.createDirectory(at: sandbox.tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: sandbox.tokenURL)
        AntigravityStubURLProtocol.state.reset(try antigravityRoutes())

        let snapshot = try await sandboxedProvider().fetch(in: sandbox.environment())

        #expect(snapshot.account == "userinfo.user@example.com")
    }

    @Test func readsGoTimestamps() throws {
        let nanos = try #require(AntigravityProvider.goTime("2026-11-05T13:00:00.123456789Z"))
        #expect(abs(nanos.timeIntervalSince1970 - 1_793_883_600.123) < 0.001)
        #expect(AntigravityProvider.goTime("2026-11-05T12:30:00+01:00") == AntigravityFixtures.date("2026-11-05T11:30:00Z"))
        #expect(AntigravityProvider.goTime("0001-01-01T00:00:00Z") == nil)
    }

    @Test func plansFromTiers() {
        typealias CodeAssist = AntigravityProvider.CodeAssist
        #expect(AntigravityProvider.plan(CodeAssist(paidTierID: "g1-ultra-tier"), hostedDomain: nil) == "Ultra")
        #expect(AntigravityProvider.plan(CodeAssist(paidTierName: "Google AI Ultra Lite"), hostedDomain: nil) == "Ultra Lite")
        #expect(AntigravityProvider.plan(CodeAssist(currentTierID: "standard-tier"), hostedDomain: nil) == "Paid")
        #expect(AntigravityProvider.plan(CodeAssist(currentTierID: "free-tier"), hostedDomain: "example.edu") == "Workspace")
        #expect(AntigravityProvider.plan(CodeAssist(), hostedDomain: nil) == nil)
    }
}
