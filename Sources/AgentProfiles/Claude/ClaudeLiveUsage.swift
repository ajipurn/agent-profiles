import Foundation
import Security
import ClaudeProfilesCore

/// Asks Anthropic for each profile's usage with Claude Desktop's own sign-in,
/// because recent Claude Desktop versions stopped saving the numbers on disk.
///
/// The "Claude Safe Storage" password that opens the sign-in is read from the
/// Keychain at most once per run (macOS asks the first time); a refusal is
/// remembered until the app restarts, so the prompt never repeats. Tokens stay
/// in memory for the request only.
actor ClaudeLiveUsage {
    /// Between two asks for one profile. Claude's Code tab keeps a good answer
    /// for a minute; the menu only needs a few.
    static let interval: TimeInterval = 120
    static let retryAfterFailure: TimeInterval = 300
    static let retryAfterRateLimit: TimeInterval = 900

    private var password: Data?
    private var passwordUnavailable = false
    private var nextAsk: [String: Date] = [:]
    private var latest: [String: ProfileUsage] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// The profile's latest live numbers, asking again when they are due.
    /// `force` (the Refresh button) skips the wait between asks, not the
    /// longer waits after a failure.
    func usage(profile: String, login: (sealed: DesktopLogin.Sealed, orgIDs: Set<String>)?,
               force: Bool = false) async -> ProfileUsage? {
        let now = Date()
        if let due = nextAsk[profile], due > now, !(force && due.timeIntervalSince(now) <= Self.interval) {
            return latest[profile]
        }
        guard let login, let password = readPassword(),
              let opened = DesktopLogin.decrypt(login.sealed.tokenCache, password: password),
              let token = DesktopLogin.best(DesktopLogin.tokens(decrypted: opened),
                                            accountID: login.sealed.accountID, orgIDs: login.orgIDs, now: now),
              let request = DesktopLogin.usageRequest(for: token)
        else {
            nextAsk[profile] = now.addingTimeInterval(Self.retryAfterFailure)
            return latest[profile]
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let usage = DesktopLogin.usage(fromResponse: data, orgID: token.orgID, asOf: Date()) {
                latest[profile] = usage
                nextAsk[profile] = now.addingTimeInterval(Self.interval)
            } else {
                nextAsk[profile] = now.addingTimeInterval(status == 429 ? Self.retryAfterRateLimit : Self.retryAfterFailure)
            }
        } catch {
            nextAsk[profile] = now.addingTimeInterval(Self.retryAfterFailure)
        }
        return latest[profile]
    }

    private func readPassword() -> Data? {
        if let password { return password }
        guard !passwordUnavailable else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            // Refused, or no such item: don't ask again this run. Anything
            // else (a locked screen) may pass, so the next round tries again.
            if [errSecSuccess, errSecUserCanceled, errSecAuthFailed, errSecItemNotFound].contains(status) {
                passwordUnavailable = true
            }
            return nil
        }
        password = data
        return data
    }
}
