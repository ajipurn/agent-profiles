import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ProvidersCore

/// Answers every request with the stubbed status and body, recording what
/// was asked. One suite uses it at a time (the suite is serialized).
final class CopilotStubURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite(.serialized) struct CopilotProviderTests {
    static let now = Date(timeIntervalSince1970: 1_793_869_200) // 2026-11-05T09:00:00Z

    let home: URL

    /// A fake home, created on first install and removed by `cleanUp`.
    init() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-tests-\(UUID().uuidString)")
    }

    func environment(variables: [String: String] = [:]) -> ProviderEnvironment {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CopilotStubURLProtocol.self]
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

    func install(_ fixture: String, at relativePath: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.fixture(fixture).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    static func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    // MARK: Mapping

    @Test func mapsPaidPlanPremiumWindowAndSkipsUnlimited() throws {
        let snapshot = try CopilotProvider.snapshot(from: Self.object("copilot-user-pro"), account: "file-user", fetchedAt: Self.now)
        #expect(snapshot.account == "octocat-fake")
        #expect(snapshot.plan == "Individual")
        #expect(snapshot.windows.map(\.title) == ["Premium"])
        let premium = try #require(snapshot.windows.first)
        #expect(premium.usedPercent == 37.5)
        #expect(premium.resetsAt == Self.utc("2026-12-01T00:00:00Z"))
        #expect(premium.windowSeconds == TimeInterval(30 * 86400)) // November
        #expect(snapshot.details == [ProviderDetail(title: "Overage", value: "4 requests")])
        #expect(snapshot.fetchedAt == Self.now)
    }

    @Test func mapsFreePlanWindowsInOrder() throws {
        let snapshot = try CopilotProvider.snapshot(from: Self.object("copilot-user-free"), account: nil, fetchedAt: Self.now)
        #expect(snapshot.plan == "Free")
        #expect(snapshot.windows.map(\.title) == ["Premium", "Chat", "Completions"])
        #expect(snapshot.windows.map(\.usedPercent) == [0, 24, 25])
        // 2026-10-20 → 2026-11-20 is 31 days.
        #expect(snapshot.windows.allSatisfy { $0.windowSeconds == 31 * 86400 })
        #expect(snapshot.details.isEmpty)
    }

    @Test func fallsBackToMonthlyAndLimitedQuotas() throws {
        let snapshot = try CopilotProvider.snapshot(from: Self.object("copilot-user-legacy-free"), account: "file-user",
                                                    fetchedAt: Self.now)
        #expect(snapshot.account == "file-user")
        #expect(snapshot.windows.map(\.title) == ["Chat", "Completions"])
        #expect(snapshot.windows.map(\.usedPercent) == [75, 75])
        #expect(snapshot.windows.first?.resetsAt == Self.utc("2026-11-20T00:00:00Z"))
    }

    @Test func tokenBilledSeatShowsPlanAndCreditsWithoutWindows() throws {
        let snapshot = try CopilotProvider.snapshot(from: Self.object("copilot-user-token-billing"), account: nil,
                                                    fetchedAt: Self.now)
        #expect(snapshot.plan == "Business")
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.details == [
            ProviderDetail(title: "Credits used", value: "31.50"),
            ProviderDetail(title: "Chat", value: "Unlimited"),
        ])
    }

    @Test func endedSubscriptionIsUnsupported() throws {
        #expect(throws: ProviderFetchError.unsupported("Copilot subscription ended.")) {
            try CopilotProvider.snapshot(from: Self.object("copilot-user-ended"), account: nil, fetchedAt: Self.now)
        }
    }

    @Test func responseWithoutQuotasIsUnsupported() {
        #expect(throws: ProviderFetchError.unsupported("Copilot reports no usage quota for this account.")) {
            try CopilotProvider.snapshot(from: ["copilot_plan": "individual"], account: nil, fetchedAt: Self.now)
        }
    }

    // MARK: Credentials and requests

    @Test func missingFilesAreNotSignedIn() async throws {
        defer { cleanUp() }
        CopilotStubURLProtocol.reset()
        let provider = CopilotProvider()
        #expect(!provider.isSignedIn(in: environment()))
        do {
            _ = try await provider.fetch(in: environment())
            Issue.record("fetch succeeded without a sign-in")
        } catch let error as ProviderFetchError {
            guard case .notSignedIn = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(CopilotStubURLProtocol.requests.isEmpty)
    }

    @Test func fetchesWithAppsJSONTokenAndCopilotHeaders() async throws {
        defer { cleanUp() }
        try install("copilot-apps", at: ".config/github-copilot/apps.json")
        CopilotStubURLProtocol.reset(body: try Self.fixture("copilot-user-pro"))
        let provider = CopilotProvider()
        #expect(provider.isSignedIn(in: environment()))

        let snapshot = try await provider.fetch(in: environment())
        #expect(snapshot.windows.first?.usedPercent == 37.5)
        let request = try #require(CopilotStubURLProtocol.requests.first)
        #expect(CopilotStubURLProtocol.requests.count == 1)
        #expect(request.url?.absoluteString == "https://api.github.com/copilot_internal/user")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token ghu_fakeToken1")
        #expect(request.value(forHTTPHeaderField: "Editor-Version") == "vscode/1.96.2")
        #expect(request.value(forHTTPHeaderField: "Editor-Plugin-Version") == "copilot-chat/0.26.7")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "GitHubCopilotChat/0.26.7")
        #expect(request.value(forHTTPHeaderField: "X-Github-Api-Version") == "2025-04-01")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func prefersGitHubDotComInHostsJSON() throws {
        defer { cleanUp() }
        try install("copilot-hosts", at: ".config/github-copilot/hosts.json")
        let credential = try #require(CopilotProvider.credential(in: environment()))
        #expect(credential == .init(host: "github.com", token: "gho_fakeToken2", user: "hosts-user-fake"))
    }

    @Test func honorsXDGConfigHome() throws {
        defer { cleanUp() }
        try install("copilot-apps", at: "xdg/github-copilot/apps.json")
        let variables = ["XDG_CONFIG_HOME": home.appendingPathComponent("xdg").path]
        #expect(CopilotProvider.credential(in: environment(variables: variables))?.user == "octocat-fake")
        #expect(CopilotProvider.credential(in: environment()) == nil)
    }

    @Test func readsCopilotCLIConfigPreferringLastUser() throws {
        defer { cleanUp() }
        try install("copilot-cli-config", at: ".copilot/config.json")
        let credential = try #require(CopilotProvider.credential(in: environment()))
        #expect(credential == .init(host: "github.com", token: "gho_fakeToken3", user: "cli-user-fake"))
    }

    @Test func enterpriseHostUsesItsAPIHost() async throws {
        defer { cleanUp() }
        let url = home.appendingPathComponent(".config/github-copilot/hosts.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"octocorp.ghe.com":{"user":"e","oauth_token":"gho_FAKEenterprise"}}"#.utf8).write(to: url)
        CopilotStubURLProtocol.reset(body: try Self.fixture("copilot-user-free"))
        _ = try await CopilotProvider().fetch(in: environment())
        #expect(CopilotStubURLProtocol.requests.first?.url?.absoluteString == "https://api.octocorp.ghe.com/copilot_internal/user")
    }

    @Test(arguments: [(401, ProviderFetchError.unauthorized), (403, .unauthorized), (500, .http(500))])
    func mapsHTTPErrors(status: Int, expected: ProviderFetchError) async throws {
        defer { cleanUp() }
        try install("copilot-apps", at: ".config/github-copilot/apps.json")
        CopilotStubURLProtocol.reset(status: status, body: Data(#"{"message":"Bad credentials"}"#.utf8))
        await #expect(throws: expected) {
            try await CopilotProvider().fetch(in: environment())
        }
    }

    @Test func unreadableBodyIsInvalidResponse() async throws {
        defer { cleanUp() }
        try install("copilot-apps", at: ".config/github-copilot/apps.json")
        CopilotStubURLProtocol.reset(body: Data("<html>".utf8))
        await #expect(throws: ProviderFetchError.invalidResponse) {
            try await CopilotProvider().fetch(in: environment())
        }
    }

    @Test func fetchDoesNotTouchCredentialFiles() async throws {
        defer { cleanUp() }
        try install("copilot-apps", at: ".config/github-copilot/apps.json")
        let url = home.appendingPathComponent(".config/github-copilot/apps.json")
        let before = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        CopilotStubURLProtocol.reset(body: try Self.fixture("copilot-user-pro"))
        _ = try await CopilotProvider().fetch(in: environment())
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)
    }
}
