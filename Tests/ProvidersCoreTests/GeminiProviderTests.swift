import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ProvidersCore

// MARK: - HTTP stub

private final class GeminiStubState: @unchecked Sendable {
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

private final class GeminiStubURLProtocol: URLProtocol {
    static let state = GeminiStubState()

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

private enum GeminiFixtures {
    /// 2026-11-05T12:00:00Z, the clock the fixtures' expiry dates are written against.
    static let now = Date(timeIntervalSince1970: 1_793_880_000)

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
}

private struct GeminiSandbox {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-provider-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    var credentialsURL: URL { home.appendingPathComponent(".gemini/oauth_creds.json") }

    func write(_ data: Data, to relativePath: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// The credentials fixture, optionally with fields replaced.
    func writeCredentials(_ fixture: String, overriding fields: [String: Any] = [:]) throws {
        var json = GeminiFixtures.object(try GeminiFixtures.data(fixture))
        for (key, value) in fields { json[key] = value }
        try write(JSONSerialization.data(withJSONObject: json), to: ".gemini/oauth_creds.json")
    }

    func environment(_ variables: [String: String] = [:]) -> ProviderEnvironment {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStubURLProtocol.self]
        return ProviderEnvironment(
            home: home,
            session: URLSession(configuration: configuration),
            now: { GeminiFixtures.now },
            variables: variables)
    }
}

/// A provider that never looks outside the sandbox for an installed Gemini CLI.
private func sandboxedProvider() -> GeminiProvider {
    var provider = GeminiProvider()
    provider.installPrefixes = []
    return provider
}

/// Routes Google's endpoints to fixtures; anything else is a 404.
private func geminiRoutes(
    loadCodeAssist: String = "gemini-load-code-assist-free",
    quota: (status: Int, fixture: String) = (200, "gemini-quota"),
    refresh: (status: Int, fixture: String) = (200, "gemini-token-refresh")
) throws -> GeminiStubState.Handler {
    let codeAssist = try GeminiFixtures.data(loadCodeAssist)
    let quotaBody = try GeminiFixtures.data(quota.fixture)
    let refreshBody = try GeminiFixtures.data(refresh.fixture)
    let projects = try GeminiFixtures.data("gemini-projects")
    return { request, _ in
        switch (request.url?.host, request.url?.path) {
        case ("oauth2.googleapis.com", "/token"): return (refresh.status, refreshBody)
        case (_, "/v1internal:loadCodeAssist"): return (200, codeAssist)
        case (_, "/v1internal:retrieveUserQuota"): return (quota.status, quotaBody)
        case ("cloudresourcemanager.googleapis.com", "/v1/projects"): return (200, projects)
        default: return (404, Data())
        }
    }
}

private func expectUnsupported(_ provider: GeminiProvider, _ environment: ProviderEnvironment,
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

@Suite(.serialized) struct GeminiProviderTests {
    @Test func mapsQuotaBucketsToFamilyWindows() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds")
        GeminiStubURLProtocol.state.reset(try geminiRoutes())

        let snapshot = try await sandboxedProvider().fetch(in: sandbox.environment())

        #expect(snapshot.account == "gemini.user@example.com")
        #expect(snapshot.plan == "Free")
        #expect(snapshot.windows.map(\.title) == ["Pro models", "Flash", "Flash Lite"])
        // Lowest remaining per family: 3 Pro preview at 0.4, 2.5 Flash at 0.9, Flash Lite at 0.8.
        #expect(snapshot.windows.map { $0.usedPercent.rounded() } == [60, 10, 20])
        #expect(snapshot.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-11-06T03:30:00Z"))
        #expect(snapshot.windows.allSatisfy { $0.windowSeconds == 86_400 })
        #expect(snapshot.fetchedAt == GeminiFixtures.now)

        let requests = GeminiStubURLProtocol.state.requests
        #expect(requests.map { $0.request.url?.path } == ["/v1internal:loadCodeAssist", "/v1internal:retrieveUserQuota"])
        #expect(requests.allSatisfy {
            $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.fake-gemini-access-token"
        })
        let codeAssistBody = GeminiFixtures.object(requests[0].body)
        #expect((codeAssistBody["metadata"] as? [String: Any])?["ideType"] as? String == "GEMINI_CLI")
        #expect(GeminiFixtures.object(requests[1].body)["project"] as? String == "fake-companion-project-123")
    }

    @Test func paidTierNameIsThePlanAndProjectObjectIsUsed() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds")
        GeminiStubURLProtocol.state.reset(try geminiRoutes(loadCodeAssist: "gemini-load-code-assist-paid"))

        let snapshot = try await sandboxedProvider().fetch(in: sandbox.environment())

        #expect(snapshot.plan == "Gemini Code Assist in Google One AI Pro")
        let quotaRequest = try #require(GeminiStubURLProtocol.state.requests.last)
        #expect(GeminiFixtures.object(quotaRequest.body)["project"] as? String == "fake-paid-project-456")
    }

    @Test func discoversTheGeminiAPIProjectWhenCodeAssistNamesNone() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds")
        GeminiStubURLProtocol.state.reset(try geminiRoutes(loadCodeAssist: "gemini-load-code-assist-no-project"))

        let snapshot = try await sandboxedProvider().fetch(in: sandbox.environment())

        #expect(snapshot.plan == "Paid")
        let requests = GeminiStubURLProtocol.state.requests
        #expect(requests.map { $0.request.url?.host } == [
            "cloudcode-pa.googleapis.com", "cloudresourcemanager.googleapis.com", "cloudcode-pa.googleapis.com",
        ])
        #expect(GeminiFixtures.object(requests[2].body)["project"] as? String == "gen-lang-client-0123456789")
    }

    @Test func missingCredentialsAreNotSignedIn() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        GeminiStubURLProtocol.state.reset(try geminiRoutes())
        let provider = sandboxedProvider()

        #expect(!provider.isSignedIn(in: sandbox.environment()))
        do {
            _ = try await provider.fetch(in: sandbox.environment())
            Issue.record("Expected notSignedIn")
        } catch ProviderFetchError.notSignedIn(let hint) {
            #expect(hint.contains("gemini"))
        }
        #expect(GeminiStubURLProtocol.state.requests.isEmpty)

        try sandbox.writeCredentials("gemini-oauth-creds")
        #expect(provider.isSignedIn(in: sandbox.environment()))
    }

    @Test func expiredTokenIsRenewedInMemoryOnly() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds-expired")
        let original = try Data(contentsOf: sandbox.credentialsURL)
        GeminiStubURLProtocol.state.reset(try geminiRoutes())
        let environment = sandbox.environment([
            "GEMINI_OAUTH_CLIENT_ID": "fake-gemini-client.apps.googleusercontent.com",
            "GEMINI_OAUTH_CLIENT_SECRET": "fake-gemini-secret",
        ])

        let snapshot = try await sandboxedProvider().fetch(in: environment)

        #expect(snapshot.account == "renewed.user@example.com")
        let requests = GeminiStubURLProtocol.state.requests
        #expect(requests.first?.request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(GeminiFixtures.form(requests[0].body) == [
            "client_id": "fake-gemini-client.apps.googleusercontent.com",
            "client_secret": "fake-gemini-secret",
            "refresh_token": "1//fake-gemini-refresh-token-expired",
            "grant_type": "refresh_token",
        ])
        #expect(requests.dropFirst().allSatisfy {
            $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.fake-gemini-renewed-token"
        })
        #expect(try Data(contentsOf: sandbox.credentialsURL) == original, "the sign-in file must not be rewritten")

        // The renewed token is reused from memory on the next fetch.
        GeminiStubURLProtocol.state.reset(try geminiRoutes())
        _ = try await sandboxedProvider().fetch(in: environment)
        #expect(!GeminiStubURLProtocol.state.requests.contains { $0.request.url?.host == "oauth2.googleapis.com" })
    }

    @Test func renewsWithTheClientFromTheInstalledCLI() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds-expired", overriding: [
            "refresh_token": "1//fake-gemini-refresh-token-installed-cli",
        ])
        // An npm-style global install: bin/gemini -> lib/node_modules/@google/gemini-cli/dist/index.js.
        let package = "prefix/lib/node_modules/@google/gemini-cli"
        try sandbox.write(Data(#"{"name": "@google/gemini-cli", "version": "0.99.0"}"#.utf8), to: "\(package)/package.json")
        try sandbox.write(Data("#!/usr/bin/env node\n".utf8), to: "\(package)/dist/index.js")
        try sandbox.write(Data("""
        import { OAuth2Client } from 'google-auth-library';
        const OAUTH_CLIENT_ID = '123456789-fakeinstalled.apps.googleusercontent.com';
        const OAUTH_CLIENT_SECRET = 'GOCSPX-fake-installed-secret';
        """.utf8), to: "\(package)/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")
        let bin = sandbox.home.appendingPathComponent("prefix/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent("gemini").path,
            withDestinationPath: "../lib/node_modules/@google/gemini-cli/dist/index.js")
        GeminiStubURLProtocol.state.reset(try geminiRoutes())

        _ = try await sandboxedProvider().fetch(in: sandbox.environment(["PATH": bin.path]))

        let refresh = try #require(GeminiStubURLProtocol.state.requests.first)
        let form = GeminiFixtures.form(refresh.body)
        #expect(form["client_id"] == "123456789-fakeinstalled.apps.googleusercontent.com")
        #expect(form["client_secret"] == "GOCSPX-fake-installed-secret")
    }

    @Test func expiredTokenWithoutAnOAuthClientExplainsHowToRenew() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds-expired", overriding: [
            "refresh_token": "1//fake-gemini-refresh-token-no-client",
        ])
        GeminiStubURLProtocol.state.reset(try geminiRoutes())

        do {
            _ = try await sandboxedProvider().fetch(in: sandbox.environment(["PATH": ""]))
            Issue.record("Expected notSignedIn")
        } catch ProviderFetchError.notSignedIn(let hint) {
            #expect(hint.contains("Run `gemini`"))
        }
        #expect(GeminiStubURLProtocol.state.requests.isEmpty)
    }

    @Test func refusedRefreshIsUnauthorized() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds-expired", overriding: [
            "refresh_token": "1//fake-gemini-refresh-token-revoked",
        ])
        GeminiStubURLProtocol.state.reset(try geminiRoutes(refresh: (400, "gemini-projects")))
        let environment = sandbox.environment(["GEMINI_OAUTH_CLIENT_ID": "id", "GEMINI_OAUTH_CLIENT_SECRET": "secret"])

        await #expect(throws: ProviderFetchError.unauthorized) {
            _ = try await sandboxedProvider().fetch(in: environment)
        }
    }

    @Test func refreshShutdownWordingMapsToAntigravity() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds-expired", overriding: [
            "refresh_token": "1//fake-gemini-refresh-token-shutdown",
        ])
        GeminiStubURLProtocol.state.reset(try geminiRoutes(refresh: (403, "gemini-token-shutdown")))
        let environment = sandbox.environment(["GEMINI_OAUTH_CLIENT_ID": "id", "GEMINI_OAUTH_CLIENT_SECRET": "secret"])

        await expectUnsupported(sandboxedProvider(), environment, containing: "Antigravity")
    }

    @Test func unsupportedClientInLoadCodeAssistMapsToAntigravity() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds")
        GeminiStubURLProtocol.state.reset(try geminiRoutes(loadCodeAssist: "gemini-load-code-assist-unsupported"))

        await expectUnsupported(sandboxedProvider(), sandbox.environment(), containing: "Use Antigravity")
        // Google answers before the quota call.
        #expect(GeminiStubURLProtocol.state.requests.count == 1)
    }

    @Test func subscriptionRequiredAfterAnUnsupportedClientFlagMapsToAntigravity() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds")
        GeminiStubURLProtocol.state.reset(try geminiRoutes(
            loadCodeAssist: "gemini-load-code-assist-flagged-free",
            quota: (403, "gemini-quota-subscription-required")))

        await expectUnsupported(sandboxedProvider(), sandbox.environment(), containing: "Antigravity")
    }

    @Test func licensedAccountSubscriptionRequiredIsNotTheShutdown() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds")
        GeminiStubURLProtocol.state.reset(try geminiRoutes(
            loadCodeAssist: "gemini-load-code-assist-paid",
            quota: (403, "gemini-quota-subscription-required")))

        await expectUnsupported(sandboxedProvider(), sandbox.environment(), containing: "license")
    }

    @Test func quotaErrorsMapToFetchErrors() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds")

        GeminiStubURLProtocol.state.reset(try geminiRoutes(quota: (401, "gemini-projects")))
        await #expect(throws: ProviderFetchError.unauthorized) {
            _ = try await sandboxedProvider().fetch(in: sandbox.environment())
        }
        GeminiStubURLProtocol.state.reset(try geminiRoutes(quota: (503, "gemini-projects")))
        await #expect(throws: ProviderFetchError.http(503)) {
            _ = try await sandboxedProvider().fetch(in: sandbox.environment())
        }
        GeminiStubURLProtocol.state.reset(try geminiRoutes(quota: (200, "gemini-projects")))
        await #expect(throws: ProviderFetchError.invalidResponse) {
            _ = try await sandboxedProvider().fetch(in: sandbox.environment())
        }
    }

    @Test func apiKeyLoginIsUnsupported() async throws {
        let sandbox = try GeminiSandbox()
        defer { sandbox.remove() }
        try sandbox.writeCredentials("gemini-oauth-creds")
        try sandbox.write(Data(#"{"security": {"auth": {"selectedType": "gemini-api-key"}}}"#.utf8),
                          to: ".gemini/settings.json")
        GeminiStubURLProtocol.state.reset(try geminiRoutes())

        await expectUnsupported(sandboxedProvider(), sandbox.environment(), containing: "API key")
        #expect(GeminiStubURLProtocol.state.requests.isEmpty)
    }

    @Test func workspaceDomainIsExemptFromTheShutdownFlag() throws {
        let json = GeminiFixtures.object(try GeminiFixtures.data("gemini-load-code-assist-unsupported"))
        let status = try GeminiProvider.parseCodeAssist(json, hostedDomain: "example.edu")
        #expect(!status.consumerClientUnsupported)

        let free = try GeminiProvider.parseCodeAssist(
            GeminiFixtures.object(try GeminiFixtures.data("gemini-load-code-assist-free")), hostedDomain: "example.edu")
        #expect(GeminiProvider.plan(free, hostedDomain: "example.edu") == "Workspace")
        #expect(GeminiProvider.plan(GeminiProvider.CodeAssist(tier: "legacy-tier"), hostedDomain: nil) == "Legacy")
        #expect(GeminiProvider.plan(GeminiProvider.CodeAssist(), hostedDomain: nil) == nil)
    }

    @Test func readsTheOAuthClientFromBundledSource() {
        let bundled = #"var OAUTH_CLIENT_ID = "42-bundle.apps.googleusercontent.com"; var OAUTH_CLIENT_SECRET = "GOCSPX-bundle_secret-1";"#
        #expect(GeminiProvider.parseClient(text: bundled)
            == GeminiProvider.OAuthClient(id: "42-bundle.apps.googleusercontent.com", secret: "GOCSPX-bundle_secret-1"))
        #expect(GeminiProvider.parseClient(text: "const OAUTH_CLIENT_ID = 'only-an-id';") == nil)
    }

    @Test func unmatchedModelsStillShowOneQuota() {
        let windows = GeminiProvider.windows(fromBuckets: [
            ["modelId": "gemini-experimental", "remainingFraction": 0.25],
        ])
        #expect(windows.map(\.title) == ["Quota"])
        #expect(windows.first?.usedPercent == 75)
    }
}
