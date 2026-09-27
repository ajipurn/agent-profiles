import Foundation

public struct UsageFetchResult: Sendable {
    public var usage: CodexUsage
    public var updatedSnapshot: AuthSnapshot?

    public init(usage: CodexUsage, updatedSnapshot: AuthSnapshot? = nil) {
        self.usage = usage
        self.updatedSnapshot = updatedSnapshot
    }
}

public enum UsageFetchError: LocalizedError, Equatable, Sendable {
    case notChatGPTSession
    case unauthorized
    case invalidResponse
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notChatGPTSession:
            "This login has no ChatGPT usage quota"
        case .unauthorized:
            "Usage requires a fresh ChatGPT login"
        case .invalidResponse:
            "Codex usage response was invalid"
        case .http(let code):
            "Codex usage request failed (\(code))"
        }
    }
}

public struct CodexUsageClient: Sendable {
    public var session: URLSession
    public var usageURL: URL
    public var fallbackUsageURL: URL?
    public var refreshURL: URL
    public var clientID: String

    public init(
        session: URLSession? = nil,
        usageURL: URL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!,
        fallbackUsageURL: URL? = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        refreshURL: URL = URL(string: "https://auth.openai.com/oauth/token")!,
        clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann"
    ) {
        self.session = session ?? Self.makeSession()
        self.usageURL = usageURL
        self.fallbackUsageURL = fallbackUsageURL
        self.refreshURL = refreshURL
        self.clientID = clientID
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }

    public func fetch(snapshot: AuthSnapshot) async throws -> UsageFetchResult {
        guard snapshot.isChatGPTSession else { throw UsageFetchError.notChatGPTSession }
        var current = snapshot
        var updated: AuthSnapshot?
        if current.accessTokenNeedsRefresh {
            current = try await refresh(current)
            updated = current
        }
        do {
            let usage = try await requestUsage(current)
            return UsageFetchResult(usage: usage, updatedSnapshot: updated)
        } catch UsageFetchError.unauthorized {
            current = try await refresh(current)
            let usage = try await requestUsage(current)
            return UsageFetchResult(usage: usage, updatedSnapshot: current)
        }
    }

    func requestUsage(_ snapshot: AuthSnapshot) async throws -> CodexUsage {
        do {
            return try await sendUsageRequest(url: usageURL, snapshot: snapshot)
        } catch UsageFetchError.http(let code) where Self.fallbackStatusCodes.contains(code) {
            guard let fallbackUsageURL, fallbackUsageURL != usageURL else {
                throw UsageFetchError.http(code)
            }
            return try await sendUsageRequest(url: fallbackUsageURL, snapshot: snapshot)
        }
    }

    func sendUsageRequest(url: URL, snapshot: AuthSnapshot) async throws -> CodexUsage {
        guard let accessToken = snapshot.accessToken else {
            throw UsageFetchError.notChatGPTSession
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-store", forHTTPHeaderField: "Pragma")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountID = snapshot.workspaceAccountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return try CodexUsage.parse(json: data)
        case 401, 403:
            throw UsageFetchError.unauthorized
        default:
            throw UsageFetchError.http(http.statusCode)
        }
    }

    func refresh(_ snapshot: AuthSnapshot) async throws -> AuthSnapshot {
        guard let refreshToken = snapshot.refreshToken else {
            throw UsageFetchError.unauthorized
        }
        var request = URLRequest(url: refreshURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UsageFetchError.unauthorized
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = root["access_token"] as? String, !accessToken.isEmpty
        else {
            throw UsageFetchError.invalidResponse
        }
        return try snapshot.applyingTokenRefresh(
            accessToken: accessToken,
            refreshToken: root["refresh_token"] as? String,
            idToken: root["id_token"] as? String
        )
    }

    private static let fallbackStatusCodes: Set<Int> = [404, 405, 410, 501]
}
