import Foundation

public struct AuthSnapshot: Equatable, Sendable {
    public var data: Data
    public var identity: AccountIdentity?

    public init(data: Data) throws {
        _ = try JSONSerialization.jsonObject(with: data)
        self.data = data
        self.identity = try AccountIdentityParser.parse(authJSON: data)
    }

    public var accountID: String? { identity?.accountID }

    public var workspaceAccountID: String? {
        tokenField("account_id")
    }

    public var accessToken: String? {
        tokenField("access_token")
    }

    public var refreshToken: String? {
        tokenField("refresh_token")
    }

    public var isChatGPTSession: Bool {
        identity?.authMode != "apikey" && !(accessToken ?? "").isEmpty
    }

    public var accessTokenExpiration: Date? {
        AccountIdentityParser.jwtExpiration(from: accessToken)
    }

    public var accessTokenNeedsRefresh: Bool {
        guard isChatGPTSession else { return false }
        guard let expiration = accessTokenExpiration else { return false }
        return expiration.timeIntervalSinceNow < 90
    }

    public func applyingTokenRefresh(
        accessToken: String,
        refreshToken: String?,
        idToken: String?
    ) throws -> AuthSnapshot {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwitcherError.invalidAuthFile
        }
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken, !idToken.isEmpty {
            tokens["id_token"] = idToken
        }
        root["tokens"] = tokens
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = formatter.string(from: Date())
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return try AuthSnapshot(data: updated)
    }

    func tokenField(_ key: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let value = tokens[key] as? String
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func matches(_ other: AuthSnapshot) -> Bool {
        if let lhs = identity, let rhs = other.identity {
            return lhs.isSameAccount(as: rhs)
        }
        return data == other.data
    }
}

public enum SwitcherError: LocalizedError, Equatable {
    case missingAuthFile
    case invalidAuthFile
    case profileNotFound
    case profileNameEmpty
    case profileNameTaken
    case io(String)
    case loginInProgress
    case loginFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            "No live Codex login found at ~/.codex/auth.json"
        case .invalidAuthFile:
            "The Codex auth file is not valid JSON"
        case .profileNotFound:
            "That saved account is gone"
        case .profileNameEmpty:
            "Give this account a name"
        case .profileNameTaken:
            "An account with that name already exists"
        case .io(let detail):
            detail
        case .loginInProgress:
            "A ChatGPT login is already in progress"
        case .loginFailed(let detail):
            "Login failed: \(detail)"
        }
    }
}

public struct LiveState: Equatable, Sendable {
    public var file: AuthSnapshot?
    public var matchingProfileID: UUID?

    public var identity: AccountIdentity? { file?.identity }
}
