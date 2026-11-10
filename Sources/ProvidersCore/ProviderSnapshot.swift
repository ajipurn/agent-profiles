import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One usage window or quota of an extra provider ("Premium requests",
/// "Pro models"), as the panel draws it.
public struct ProviderWindow: Equatable, Sendable {
    public var title: String
    /// Used share, 0–100.
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Length of the window, for pacing. Nil when unknown.
    public var windowSeconds: TimeInterval?

    public init(title: String, usedPercent: Double, resetsAt: Date? = nil, windowSeconds: TimeInterval? = nil) {
        self.title = title
        self.usedPercent = min(100, max(0, usedPercent.isFinite ? usedPercent : 0))
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    public var remainingPercent: Double { 100 - usedPercent }
}

/// A value worth its own line: a balance, credits used, spend this month.
public struct ProviderDetail: Equatable, Sendable {
    public var title: String
    public var value: String
    /// Used share of a cap, 0–100, when there is one.
    public var usedPercent: Double?

    public init(title: String, value: String, usedPercent: Double? = nil) {
        self.title = title
        self.value = value
        self.usedPercent = usedPercent
    }
}

/// Everything one fetch of an extra provider returns.
public struct ProviderSnapshot: Equatable, Sendable {
    /// Signed-in account (email or login), if the provider says.
    public var account: String?
    /// Plan name ("Pro", "Business").
    public var plan: String?
    /// Most important first: the first window drives the menu bar icon's
    /// top bar, the second its bottom bar.
    public var windows: [ProviderWindow]
    public var details: [ProviderDetail]
    public var fetchedAt: Date

    public init(account: String? = nil, plan: String? = nil, windows: [ProviderWindow] = [],
                details: [ProviderDetail] = [], fetchedAt: Date = Date()) {
        self.account = account
        self.plan = plan
        self.windows = windows
        self.details = details
        self.fetchedAt = fetchedAt
    }
}

public enum ProviderFetchError: LocalizedError, Equatable, Sendable {
    /// No local sign-in found; the message says how to sign in.
    case notSignedIn(String)
    /// The saved sign-in was refused; sign in again in the provider's own tool.
    case unauthorized
    case http(Int)
    case invalidResponse
    /// The account exists but has nothing this app can show (an API key
    /// login, an ended subscription); the message says which.
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn(let hint): hint
        case .unauthorized: "Sign-in expired. Sign in again in the provider's own app or CLI."
        case .http(let code): "Usage request failed (\(code))."
        case .invalidResponse: "The usage response could not be read."
        case .unsupported(let reason): reason
        }
    }
}

/// Where a provider looks for things, so tests can point it at fixtures.
public struct ProviderEnvironment: Sendable {
    public var home: URL
    public var session: URLSession
    public var now: @Sendable () -> Date
    /// Environment variables (CODEX_HOME-style overrides).
    public var variables: [String: String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                session: URLSession = ProviderEnvironment.makeSession(),
                now: @escaping @Sendable () -> Date = { Date() },
                variables: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.session = session
        self.now = now
        self.variables = variables
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }
}

/// A usage source other than Claude and Codex (which have their own
/// account switching). Read-only: a provider reads the sign-in its own tool
/// left on disk and asks that service for usage. It never writes those
/// files, so refreshed tokens live in memory only.
public protocol UsageProvider: Sendable {
    /// Stable key for settings ("gemini").
    var id: String { get }
    var name: String { get }
    /// Brand color as "#RRGGBB".
    var brandHex: String { get }
    /// SF Symbol standing in for the provider's logo.
    var symbol: String { get }
    /// Dashboard to open from the panel.
    var dashboardURL: URL? { get }
    /// Statuspage base URL (".../api/v2/status.json" is appended), if any.
    var statusPageURL: URL? { get }

    /// True when a local sign-in exists. Touches only the file system (and,
    /// for Antigravity, a Keychain item's attributes, which never prompts).
    func isSignedIn(in environment: ProviderEnvironment) -> Bool
    func fetch(in environment: ProviderEnvironment) async throws -> ProviderSnapshot
}

public extension UsageProvider {
    var dashboardURL: URL? { nil }
    var statusPageURL: URL? { nil }
}
