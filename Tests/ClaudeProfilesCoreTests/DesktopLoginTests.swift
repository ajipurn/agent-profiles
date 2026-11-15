import Foundation
import Testing
@testable import ClaudeProfilesCore

struct DesktopLoginTests {
    static let account = "11111111-1111-1111-1111-111111111111"
    static let org = "22222222-2222-2222-2222-222222222222"
    static let otherOrg = "33333333-3333-3333-3333-333333333333"
    static let host = "https://api.anthropic.com"
    static let codeScope = "user:profile user:inference user:sessions:claude_code"

    /// Made with openssl: PBKDF2-SHA1("test-safe-storage-password", "saltysalt",
    /// 1003) as the AES-128-CBC key, an IV of spaces, "v10" in front.
    static let sealedVector = "djEwGwpy0x1rv91AJu25Bh210qcKzKJ9UzyP/AAepvAGBDgpOisgywEv1nN4I4M76lgCKifD0h0DG6AwaMYn3h6HZBkkX6oQvDx55YWZk4HyPocvfHini1a2ViLOykmSaRBDWoSg6X6kVUH3b7fzs/jhJMkg1dSK9zzqa4rHxZMovSC6FafjvSKfalAu6D+obRU4JjF2SPqVX5zttnUyg5Q21J83MwWp6B+rdY+KqESP06igcK7XsFTIalosDOcj2LCFkE6uilgQSeClopejsJSC8E5jicb+r9ZZuiHPkxCoDOnuXJ3oJm9RjnbGmBU1qb3D"

    static func token(_ name: String, org: String = org, account: String? = account,
                      scope: String = codeScope, expiresIn: TimeInterval = 3600) -> DesktopLogin.Token {
        .init(accessToken: name, expiresAt: Date().addingTimeInterval(expiresIn), orgID: org,
              accountID: account, apiHost: host, scope: scope)
    }

    #if canImport(CommonCrypto)
    @Test func opensClaudesSafeStorageValue() throws {
        let opened = try #require(DesktopLogin.decrypt(Self.sealedVector, password: Data("test-safe-storage-password".utf8)))
        let tokens = DesktopLogin.tokens(decrypted: opened)
        #expect(tokens.count == 1)
        #expect(tokens.first?.accessToken == "code-token")
        #expect(tokens.first?.orgID == Self.org)
        #expect(tokens.first?.accountID == Self.account)
        #expect(tokens.first?.apiHost == Self.host)
        #expect(tokens.first?.scope == Self.codeScope)
        #expect(tokens.first?.expiresAt == Date(timeIntervalSince1970: 4_102_444_800))
    }

    @Test func wrongPasswordOrFormatOpensNothing() {
        #expect(DesktopLogin.decrypt(Self.sealedVector, password: Data("wrong".utf8)).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        } == nil)
        #expect(DesktopLogin.decrypt(Data("v11abcdefghijklmnop".utf8).base64EncodedString(), password: Data("x".utf8)) == nil)
        #expect(DesktopLogin.decrypt("not base64", password: Data("x".utf8)) == nil)
    }
    #endif

    @Test func readsKeysWithAndWithoutAccountAndPort() throws {
        let json: [String: Any] = [
            "acct:\(Self.account)|client:\(Self.org):https://api.anthropic.com:user:profile": [
                "token": "a", "refreshToken": "r", "expiresAt": 1_900_000_000_000,
            ],
            "client:\(Self.otherOrg):http://localhost:8080:user:inference user:profile": [
                "token": "b", "expiresAt": 1_900_000_000_000,
            ],
            "acct:\(Self.account)|client:\(Self.org):https://api.anthropic.com:org:create_api_key": NSNull(),
            "acct:\(Self.account)|client:\(Self.org):https://api.anthropic.com:user:mcp": [
                "token": "", "refreshToken": "r", "expiresAt": 0,
            ],
            "garbage": ["token": "c", "expiresAt": 1],
        ]
        let tokens = DesktopLogin.tokens(decrypted: try JSONSerialization.data(withJSONObject: json))
            .sorted { $0.accessToken < $1.accessToken }
        #expect(tokens.map(\.accessToken) == ["a", "b"])
        #expect(tokens[0].accountID == Self.account)
        #expect(tokens[0].apiHost == "https://api.anthropic.com")
        #expect(tokens[0].scope == "user:profile")
        #expect(tokens[1].accountID == nil)
        #expect(tokens[1].orgID == Self.otherOrg)
        #expect(tokens[1].apiHost == "http://localhost:8080")
        #expect(tokens[1].scope == "user:inference user:profile")
    }

    @Test func prefersTheCodeTabTokenOfTheSignedInAccount() {
        let everyday = Self.token("everyday", scope: "user:profile user:inference", expiresIn: 7200)
        let code = Self.token("code")
        let expired = Self.token("expired-code", expiresIn: 30)
        let otherAccount = Self.token("other-account", account: "44444444-4444-4444-4444-444444444444",
                                      expiresIn: 9000)
        let pool = [everyday, code, expired, otherAccount]
        #expect(DesktopLogin.best(pool, accountID: Self.account, orgIDs: [Self.org])?.accessToken == "code")
        #expect(DesktopLogin.best([everyday, expired], accountID: Self.account, orgIDs: [])?.accessToken == "everyday")
        #expect(DesktopLogin.best([expired], accountID: Self.account, orgIDs: []) == nil)
    }

    @Test func staysWithTheProfilesOrganizations() {
        let mine = Self.token("mine", scope: "user:profile")
        let other = Self.token("other", org: Self.otherOrg)
        #expect(DesktopLogin.best([mine, other], accountID: Self.account, orgIDs: [Self.org])?.accessToken == "mine")
        // An org list that matches nothing doesn't rule every token out.
        #expect(DesktopLogin.best([other], accountID: Self.account, orgIDs: [Self.org])?.accessToken == "other")
    }

    @Test func asksLikeClaudesCodeTab() throws {
        let request = try #require(DesktopLogin.usageRequest(for: Self.token("abc")))
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        let insecure = DesktopLogin.Token(accessToken: "abc", expiresAt: .distantFuture, orgID: Self.org,
                                          accountID: nil, apiHost: "http://example.com", scope: "user:profile")
        #expect(DesktopLogin.usageRequest(for: insecure) == nil)
    }

    @Test func decodesTheUsageAnswer() throws {
        let body = Data("""
        {"five_hour":{"utilization":2.0,"resets_at":"2026-11-15T12:20:00.000000+00:00"},
         "seven_day":{"utilization":0.0,"resets_at":"2026-11-18T14:00:00.000000+00:00"},
         "seven_day_opus":null,
         "limits":[{"kind":"weekly_scoped","percent":5,"resets_at":"2026-11-18T14:00:00Z",
                    "scope":{"model":{"display_name":"Fable"}}}],
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":120,"utilization":2.4,"currency":"USD"}}
        """.utf8)
        let now = Date()
        let usage = try #require(DesktopLogin.usage(fromResponse: body, orgID: Self.org, asOf: now))
        #expect(usage.fiveHour?.percent == 2)
        #expect(usage.fiveHour?.resetsAt != nil)
        #expect(usage.sevenDay?.percent == 0)
        #expect(usage.scoped.map(\.name) == ["Fable"])
        #expect(usage.asOf == now)
        #expect(usage.orgID == Self.org)
    }

    @Test func readsTheSealedCacheFromConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config: [String: Any] = ["oauth:tokenCacheV2": "djEwAAAA", "lastKnownAccountUuid": Self.account, "locale": "en"]
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("config.json"))
        #expect(DesktopLogin.sealed(inProfileDir: dir) == .init(tokenCache: "djEwAAAA", accountID: Self.account))
        try JSONSerialization.data(withJSONObject: ["locale": "en"]).write(to: dir.appendingPathComponent("config.json"))
        #expect(DesktopLogin.sealed(inProfileDir: dir) == nil)
    }
}
