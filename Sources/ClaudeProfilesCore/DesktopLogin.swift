import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Claude Desktop's own sign-in, read from a profile's `config.json` so the
/// usage numbers can be asked for live: recent Claude Desktop versions no
/// longer save them in their HTTP cache.
///
/// Claude keeps its OAuth tokens there as `oauth:tokenCacheV2`, sealed by
/// Electron's safeStorage (Chromium's "v10" scheme: AES-128-CBC under a key
/// derived from the "Claude Safe Storage" Keychain password). A token is only
/// sent to Anthropic's own usage endpoint, the one Claude's Code tab asks. It
/// is never refreshed, written back or saved: refreshing would rotate
/// Claude's refresh token out from under it.
public enum DesktopLogin {
    public struct Token: Equatable, Sendable {
        public let accessToken: String
        public let expiresAt: Date
        public let orgID: String
        /// The account the entry was cached for; nil on older entries.
        public let accountID: String?
        public let apiHost: String
        public let scope: String
    }

    /// The still-sealed token cache and the account Claude last signed in as.
    public struct Sealed: Equatable, Sendable {
        public let tokenCache: String
        public let accountID: String?
    }

    /// The scope Claude adds to the Code tab's token, which is the one Claude
    /// itself sends to the usage endpoint.
    static let codeScope = "user:sessions:claude_code"
    /// Tokens this close to expiring are left alone.
    static let expiryMargin: TimeInterval = 60

    public static func sealed(inProfileDir dir: URL) -> Sealed? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = json["oauth:tokenCacheV2"] as? String, !cache.isEmpty
        else { return nil }
        return Sealed(tokenCache: cache, accountID: json["lastKnownAccountUuid"] as? String)
    }

    /// Opens a safeStorage value: base64 of "v10" + AES-128-CBC ciphertext,
    /// keyed by PBKDF2-SHA1(password, "saltysalt", 1003 rounds), IV of spaces.
    public static func decrypt(_ base64: String, password: Data) -> Data? {
        #if canImport(CommonCrypto)
        guard let raw = Data(base64Encoded: base64), raw.starts(with: Array("v10".utf8)) else { return nil }
        let cipher = Data(raw.dropFirst(3))
        guard !cipher.isEmpty, cipher.count % kCCBlockSizeAES128 == 0 else { return nil }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derived = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = cipher.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, input.baseAddress, cipher.count, &out, out.count, &moved)
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
        #else
        return nil
        #endif
    }

    /// Every entry of an opened token cache that carries an access token.
    /// Keys read `[acct:<account>|]<client>:<org>:<apiHost>:<scope>`, values
    /// `{token, refreshToken, expiresAt (ms)}` or null for a signed-out entry.
    public static func tokens(decrypted: Data) -> [Token] {
        guard let json = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else { return [] }
        return json.compactMap { key, value in
            guard let entry = value as? [String: Any],
                  let token = entry["token"] as? String, !token.isEmpty,
                  let expires = UsageReader.number(entry["expiresAt"]),
                  let parts = parseKey(key)
            else { return nil }
            return Token(accessToken: token, expiresAt: Date(timeIntervalSince1970: expires / 1000),
                         orgID: parts.org, accountID: parts.account, apiHost: parts.apiHost, scope: parts.scope)
        }
    }

    static func parseKey(_ key: String) -> (account: String?, org: String, apiHost: String, scope: String)? {
        var rest = Substring(key)
        var account: String?
        if rest.hasPrefix("acct:"), let bar = rest.firstIndex(of: "|") {
            account = String(rest[rest.index(rest.startIndex, offsetBy: 5) ..< bar])
            rest = rest[rest.index(after: bar)...]
        }
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].count == 36 else { return nil }
        // The host is a URL origin, scheme://host[:port], and the scope after
        // it has colons of its own ("user:profile user:inference").
        let tail = parts[2]
        guard let scheme = tail.range(of: "://"),
              let colon = tail[scheme.upperBound...].firstIndex(of: ":") else { return nil }
        var hostEnd = colon
        let afterColon = tail[tail.index(after: colon)...]
        if let next = afterColon.firstIndex(of: ":"), !afterColon[..<next].isEmpty,
           afterColon[..<next].allSatisfy(\.isASCII), afterColon[..<next].allSatisfy(\.isNumber) {
            hostEnd = next
        }
        let scope = tail[tail.index(after: hostEnd)...]
        guard !scope.isEmpty else { return nil }
        return (account, String(parts[1]), String(tail[..<hostEnd]), String(scope))
    }

    /// The token to ask with: an unexpired one for the account Claude last
    /// signed in as and one of the profile's organizations, preferring the
    /// Code tab's, then the one that expires last (the latest refreshed).
    public static func best(_ tokens: [Token], accountID: String?, orgIDs: Set<String>,
                            now: Date = Date()) -> Token? {
        var pool = tokens.filter { $0.expiresAt.timeIntervalSince(now) > expiryMargin }
        if let accountID {
            let mine = pool.filter { $0.accountID == accountID }
            pool = mine.isEmpty ? pool.filter { $0.accountID == nil } : mine
        }
        if !orgIDs.isEmpty {
            let matching = pool.filter { orgIDs.contains($0.orgID) }
            if !matching.isEmpty { pool = matching }
        }
        return pool.max { a, b in
            let aCode = a.scope.split(separator: " ").contains(Substring(codeScope))
            let bCode = b.scope.split(separator: " ").contains(Substring(codeScope))
            return aCode == bCode ? a.expiresAt < b.expiresAt : bCode
        }
    }

    /// `GET <apiHost>/api/oauth/usage`, as Claude's Code tab sends it.
    public static func usageRequest(for token: Token) -> URLRequest? {
        let host = token.apiHost.hasSuffix("/") ? String(token.apiHost.dropLast()) : token.apiHost
        guard let url = URL(string: host + "/api/oauth/usage"), url.scheme == "https" else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
    }

    /// The usage endpoint answers in the same shape Claude used to cache.
    public static func usage(fromResponse data: Data, orgID: String, asOf: Date) -> ProfileUsage? {
        UsageReader.decode(body: data, orgID: orgID, asOf: asOf)
    }
}
