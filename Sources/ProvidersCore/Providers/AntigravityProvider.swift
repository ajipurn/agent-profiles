import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PlatformSupport

/// Google Antigravity's model quota, grouped and ordered as Antigravity's own
/// Usage view shows it (Gemini models, Claude and GPT models, Gemini 4 Argon;
/// weekly, then 5-hour). While the Antigravity app runs, the numbers come
/// from its language server on localhost, the source of that view and the
/// only one with model-specific allowances such as Argon. Otherwise they come
/// from Cloud Code, the lower of its two hosts per pool.
///
/// Plan and account always come from Cloud Code, with the Google sign-in that
/// the Antigravity app and the `agy` CLI share. On macOS they keep it in the login Keychain
/// (go-keyring, service `gemini`, account `antigravity`), read through
/// `/usr/bin/security`, which the item trusts, so there is no prompt.
/// Elsewhere, and where no keyring is available, `agy` keeps it in
/// `~/.gemini/antigravity-cli/antigravity-oauth-token`.
///
/// An expired access token is renewed in memory with Antigravity's OAuth
/// client (`ANTIGRAVITY_OAUTH_CLIENT_ID` / `_SECRET`, or read from the
/// installed `agy` / Antigravity app); reading usage never writes the stored
/// sign-in. Only switching accounts does (`AntigravityAccounts`).
public struct AntigravityProvider: UsageProvider {
    public let id = "antigravity"
    public let name = "Antigravity"
    public let brandHex = "#60BA7E"
    public let symbol = "balloon"
    public let appBundleIDs = ["com.google.antigravity"]

    /// Where installed artifacts are looked for (the `agy` binary and the
    /// Antigravity app bundles). Nil means the defaults; tests set it.
    var artifactSearchPaths: [URL]?
    /// The Keychain sign-in. Nil means the login Keychain; tests set it.
    var keychainSignIn: (@Sendable () -> String?)?
    /// A saved account's sign-in (its stored JSON) to read in place of
    /// Antigravity's own. Its numbers come from Cloud Code: the running
    /// app's language server only knows the account signed in there.
    var savedSignIn: String?

    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"

    public init() {}

    /// Reads a saved account's usage (see `AntigravityAccounts`).
    public init(savedSignIn: String) {
        self.savedSignIn = savedSignIn
    }

    public func isSignedIn(in environment: ProviderEnvironment) -> Bool {
        if savedSignIn != nil { return true }
        if FileManager.default.fileExists(atPath: Self.tokenURL(environment).path) { return true }
        if let keychainSignIn { return keychainSignIn() != nil }
        return GoKeyring.contains(service: Self.keychainService, account: Self.keychainAccount)
    }

    public func fetch(in environment: ProviderEnvironment) async throws -> ProviderSnapshot {
        let credentials = try readCredentials(environment)
        let token = try await accessToken(for: credentials, in: environment)
        let claims = ProviderJSON.jwtClaims(token.idToken)

        let codeAssist = try await Self.loadCodeAssist(accessToken: token.accessToken, in: environment)
        let bodies: [Data]
        if savedSignIn == nil, let local = await Self.localSummary(in: environment) {
            bodies = [local]
        } else {
            bodies = try await Self.quotaSummaries(
                accessToken: token.accessToken, project: codeAssist.project, in: environment)
        }
        let windows = Self.windows(fromSummaries: bodies)
        guard !windows.isEmpty else {
            throw ProviderFetchError.unsupported("Antigravity reported no quota limits for this account.")
        }
        var plan = Self.plan(codeAssist, hostedDomain: ProviderJSON.string(claims?["hd"]))
        // A measured 5-hour pool contradicts a generic "Free" tier label.
        if plan == "Free", windows.contains(where: { $0.windowSeconds == Self.fiveHours }) { plan = nil }

        var account = ProviderJSON.string(claims?["email"]) ?? credentials.email
        if account == nil {
            account = await Self.userInfoEmail(accessToken: token.accessToken, in: environment)
        }
        return ProviderSnapshot(account: account, plan: plan, windows: windows,
                                primaryWindows: Self.primaryWindows(windows), fetchedAt: environment.now())
    }

    /// The first group's 5-hour and weekly windows (Gemini models), for the
    /// menu bar icon's top and bottom bars.
    static func primaryWindows(_ windows: [ProviderWindow]) -> [ProviderWindow]? {
        let primary = [fiveHours, week].compactMap { seconds in windows.first { $0.windowSeconds == seconds } }
        return primary.isEmpty ? nil : primary
    }

    // MARK: - Endpoints

    static let cloudCodeBases = ["https://cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.googleapis.com"]
    static let oauthTokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    static let clientMetadata = ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]

    /// The shape of Antigravity's own client identity; Google treats other
    /// callers as an unsupported client and drops the paid tier.
    static let userAgent: String = {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        #if os(macOS)
        let os = "darwin"
        #elseif os(Windows)
        let os = "windows"
        #else
        let os = "linux"
        #endif
        return "antigravity/2.24.0 (aidev_client; os_type=\(os); arch=\(arch))"
    }()

    static let fiveHours: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86_400

    // MARK: - Stored sign-in

    static func tokenURL(_ environment: ProviderEnvironment) -> URL {
        environment.home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    struct Credentials: Equatable {
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Date?
        var email: String?
    }

    /// The `agy` token file when there is one (it holds an ID token), else the Keychain item.
    func readCredentials(_ environment: ProviderEnvironment) throws -> Credentials {
        if let savedSignIn {
            guard let json = Self.object(Data(savedSignIn.utf8)) else {
                throw ProviderFetchError.notSignedIn("This saved Antigravity sign-in couldn't be read. Add the account again.")
            }
            return Self.credentials(json)
        }
        let url = Self.tokenURL(environment)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let json = ProviderJSON.readObject(at: url) else {
                throw ProviderFetchError.notSignedIn(
                    "Antigravity's sign-in file couldn't be read. Run `agy` and sign in again.")
            }
            return Self.credentials(json)
        }
        let stored = keychainSignIn.map { $0() }
            ?? GoKeyring.password(service: Self.keychainService, account: Self.keychainAccount)
        if let stored {
            guard let json = Self.object(Data(stored.utf8)) else {
                throw ProviderFetchError.notSignedIn(
                    "Antigravity's saved sign-in couldn't be read. Sign out of Antigravity and sign in again.")
            }
            return Self.credentials(json)
        }
        throw ProviderFetchError.notSignedIn(
            "No Antigravity sign-in found. Sign in to the Antigravity app or the `agy` CLI.")
    }

    /// `{"token": {"access_token", "refresh_token", "expiry"}, "auth_method", "id_token"}`,
    /// the JSON form of Go's `oauth2.Token` that Antigravity writes. The
    /// Keychain copy carries `id_token_email` in place of the ID token.
    static func credentials(_ json: [String: Any]) -> Credentials {
        let token = (json["token"] as? [String: Any]) ?? json
        return Credentials(
            accessToken: ProviderJSON.string(token["access_token"] ?? token["accessToken"]),
            refreshToken: ProviderJSON.string(token["refresh_token"] ?? token["refreshToken"]),
            idToken: ProviderJSON.string(json["id_token"] ?? token["id_token"] ?? json["idToken"]),
            expiresAt: goTime(token["expiry"] ?? token["expiry_date"]),
            email: ProviderJSON.string(json["id_token_email"]))
    }

    /// Go writes RFC 3339 with up to nine fractional digits; the zero time
    /// means "no expiry".
    static func goTime(_ value: Any?) -> Date? {
        guard var text = ProviderJSON.string(value) else { return ProviderJSON.date(value) }
        if let regex = try? NSRegularExpression(pattern: #"(\.\d{3})\d+"#) {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        guard let date = ProviderJSON.date(text), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    // MARK: - Access token

    private struct CachedToken: Sendable {
        var accessToken: String
        var idToken: String?
        var expiresAt: Date
    }

    /// Tokens renewed in this process, by refresh token. Never persisted.
    private static let renewedTokens = LockedValue<[String: CachedToken]>([:])
    /// The client that last renewed a sign-in; tried first next time.
    private static let workingClient = LockedValue<OAuthClient?>(nil)
    /// Sign-ins (refresh token and candidates, hashed) that no candidate
    /// could renew, so a poll doesn't ask Google again until either changes.
    private static let unrenewable = LockedValue<Set<Int>>([])

    static let expiredHint = "Antigravity's saved sign-in has expired. Open Antigravity or run `agy` once to renew it, "
        + "or set ANTIGRAVITY_OAUTH_CLIENT_ID and ANTIGRAVITY_OAUTH_CLIENT_SECRET."

    func accessToken(for credentials: Credentials,
                     in environment: ProviderEnvironment) async throws -> (accessToken: String, idToken: String?) {
        let now = environment.now()
        if let token = credentials.accessToken,
           credentials.expiresAt.map({ $0.timeIntervalSince(now) > 60 }) ?? true {
            return (token, credentials.idToken)
        }
        guard let refreshToken = credentials.refreshToken else { throw ProviderFetchError.unauthorized }
        if let cached = Self.renewedTokens.withLock({ $0[refreshToken] }), cached.expiresAt.timeIntervalSince(now) > 60 {
            return (cached.accessToken, cached.idToken ?? credentials.idToken)
        }
        let clients = oauthClients(in: environment, idToken: credentials.idToken)
        var hasher = Hasher()
        hasher.combine(refreshToken)
        hasher.combine(clients)
        let attempt = hasher.finalize()
        guard !clients.isEmpty, !Self.unrenewable.withLock({ $0.contains(attempt) }) else {
            throw ProviderFetchError.notSignedIn(Self.expiredHint)
        }
        for client in clients {
            let request = ProviderHTTP.request(Self.oauthTokenURL, method: "POST", formBody: [
                "client_id": client.id,
                "client_secret": client.secret,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ])
            let (status, data) = try await Self.send(request, in: environment)
            guard (200...299).contains(status) else {
                if status >= 500 { throw ProviderFetchError.http(status) }
                if Self.isWrongClient(status, data) { continue }
                throw ProviderFetchError.unauthorized
            }
            guard let json = Self.object(data), let accessToken = ProviderJSON.string(json["access_token"]) else {
                throw ProviderFetchError.invalidResponse
            }
            Self.workingClient.withLock { $0 = client }
            let renewed = CachedToken(
                accessToken: accessToken,
                idToken: ProviderJSON.string(json["id_token"]),
                expiresAt: now.addingTimeInterval(ProviderJSON.double(json["expires_in"]) ?? 3600))
            Self.renewedTokens.withLock { $0[refreshToken] = renewed }
            return (accessToken, renewed.idToken ?? credentials.idToken)
        }
        Self.unrenewable.withLock { _ = $0.insert(attempt) }
        throw ProviderFetchError.notSignedIn(Self.expiredHint)
    }

    /// Google's answer to a client that didn't issue the refresh token
    /// (`unauthorized_client`) or a mismatched secret (`invalid_client`).
    static func isWrongClient(_ status: Int, _ data: Data) -> Bool {
        guard status == 400 || status == 401 else { return false }
        let error = ProviderJSON.string(object(data)?["error"])
        return error == "unauthorized_client" || error == "invalid_client"
    }

    // MARK: - OAuth client

    struct OAuthClient: Hashable, Sendable {
        var id: String
        var secret: String
    }

    /// Clients to renew with, most likely first: the environment's pair alone
    /// when set, else the pairings found in the installed artifacts.
    func oauthClients(in environment: ProviderEnvironment, idToken: String?) -> [OAuthClient] {
        let variables = environment.variables
        if let id = ProviderJSON.string(variables["ANTIGRAVITY_OAUTH_CLIENT_ID"]),
           let secret = ProviderJSON.string(variables["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]) {
            return [OAuthClient(id: id, secret: secret)]
        }
        // The ID token's audience names the client that issued the sign-in.
        // The Keychain copy has no ID token, so every pairing is a candidate.
        let claims = ProviderJSON.jwtClaims(idToken)
        let audience = ProviderJSON.string(claims?["aud"]) ?? ProviderJSON.string(claims?["azp"])
        var clients: [OAuthClient] = []
        for artifact in artifactURLs(in: environment) {
            for client in Self.cachedClients(inArtifact: artifact, audience: audience) where !clients.contains(client) {
                clients.append(client)
            }
        }
        clients = Array(clients.prefix(Self.maxCandidates))
        if let working = Self.workingClient.withLock({ $0 }), let index = clients.firstIndex(of: working) {
            clients.insert(clients.remove(at: index), at: 0)
        }
        return clients
    }

    /// `agy` first (it issued the token file), then the Antigravity app bundles.
    func artifactURLs(in environment: ProviderEnvironment) -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let url = url.resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted, fileManager.fileExists(atPath: url.path) else { return }
            urls.append(url)
        }
        if let paths = artifactSearchPaths {
            paths.forEach(add)
            return urls
        }
        let pathDirectories = (environment.variables["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let binDirectories = pathDirectories + [
            environment.home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]
        for directory in binDirectories { add(directory.appendingPathComponent("agy")) }

        let applicationRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            environment.home.appendingPathComponent("Applications", isDirectory: true),
        ]
        let bundleFiles = [
            "Contents/Resources/bin/language_server",
            "Contents/Resources/bin/language_server_macos",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos",
            "Contents/Resources/app/out/main.js",
        ]
        for root in applicationRoots {
            for app in ["Antigravity.app", "Antigravity IDE.app"] {
                for file in bundleFiles { add(root.appendingPathComponent(app).appendingPathComponent(file)) }
            }
        }
        return urls
    }

    private struct ScanResult: Sendable {
        var ids: Set<String>
        var secrets: Set<String>
    }

    /// Scans by path, size and modification date, so a large binary is read once.
    private static let scans = LockedValue<[String: ScanResult]>([:])

    static func cachedClients(inArtifact url: URL, audience: String?) -> [OAuthClient] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = [url.path,
                   "\((attributes?[.size] as? NSNumber)?.int64Value ?? -1)",
                   "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"].joined(separator: "|")
        let result: ScanResult
        if let cached = scans.withLock({ $0[key] }) {
            result = cached
        } else {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
            result = scan(data)
            scans.withLock { $0[key] = result }
        }
        return clients(from: result, audience: audience)
    }

    /// Text artifacts keep the pair next to this module; binaries are scanned whole.
    static func clients(inArtifact data: Data, audience: String?) -> [OAuthClient] {
        clients(from: scan(data), audience: audience)
    }

    private static func scan(_ data: Data) -> ScanResult {
        // The offset arithmetic below assumes zero-based indices.
        let data = data.startIndex == 0 ? data : Data(data)
        let marker = Array("vs/platform/cloudCode/common/oauthClient.js".utf8)
        if let start = offsets(of: marker, in: data, limit: 1).first {
            let window = data.subdata(in: start..<min(data.count, start + 4000))
            let result = scanWhole(window)
            if !result.ids.isEmpty, !result.secrets.isEmpty { return result }
        }
        return scanWhole(data)
    }

    private static func scanWhole(_ data: Data) -> ScanResult {
        let idSuffix = Array(".apps.googleusercontent.com".utf8)
        var ids = Set<String>()
        for offset in offsets(of: idSuffix, in: data, limit: 64) {
            var start = offset
            while start > max(0, offset - 256), isTokenByte(data[data.startIndex + start - 1]) { start -= 1 }
            guard let prefix = String(data: data.subdata(in: start..<offset), encoding: .ascii),
                  let regex = try? NSRegularExpression(pattern: #"[0-9]+-[A-Za-z0-9_-]+$"#),
                  let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
                  let range = Range(match.range, in: prefix) else { continue }
            ids.insert(String(prefix[range]) + ".apps.googleusercontent.com")
        }
        let secretPrefix = Array("GOCSPX-".utf8)
        var secrets = Set<String>()
        for offset in offsets(of: secretPrefix, in: data, limit: 64) {
            let end = offset + secretPrefix.count + 28
            guard end <= data.count else { continue }
            let body = data.subdata(in: (offset + secretPrefix.count)..<end)
            guard body.allSatisfy(isTokenByte), let text = String(data: body, encoding: .ascii) else { continue }
            secrets.insert("GOCSPX-" + text)
        }
        return ScanResult(ids: ids, secrets: secrets)
    }

    /// An artifact with more pairings than this is too ambiguous to try.
    static let maxCandidates = 9

    /// Every pairing of the client IDs (only the one the ID token names, when
    /// known) with the secrets, in a repeatable order. Go binaries pool their
    /// string constants by length, so which secret goes with which ID can't be
    /// read off the file; Google's answer tells them apart.
    private static func clients(from result: ScanResult, audience: String?) -> [OAuthClient] {
        let ids: [String]
        if let audience {
            guard result.ids.contains(where: { $0.hasSuffix(audience) }) else { return [] }
            ids = [audience]
        } else {
            ids = result.ids.sorted()
        }
        let secrets = result.secrets.sorted()
        guard ids.count * secrets.count <= maxCandidates else { return [] }
        return ids.flatMap { id in secrets.map { OAuthClient(id: id, secret: $0) } }
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
    }

    private static func offsets(of needle: [UInt8], in data: Data, limit: Int) -> [Int] {
        data.withUnsafeBytes { buffer -> [Int] in
            guard let base = buffer.baseAddress else { return [] }
            var found: [Int] = []
            var start = 0
            while found.count < limit, start < buffer.count,
                  let hit = ByteSearch.find(needle, in: base + start, count: buffer.count - start) {
                let offset = base.distance(to: hit)
                found.append(offset)
                start = offset + needle.count
            }
            return found
        }
    }

    // MARK: - Code Assist

    struct CodeAssist: Equatable {
        var project: String?
        var currentTierID: String?
        var currentTierName: String?
        var paidTierID: String?
        var paidTierName: String?
        var planType: String?
    }

    /// Project and plan, tried on production then the daily host. A refused
    /// token stops here; anything else leaves them unknown.
    static func loadCodeAssist(accessToken: String, in environment: ProviderEnvironment) async throws -> CodeAssist {
        for base in cloudCodeBases {
            guard let url = URL(string: base + "/v1internal:loadCodeAssist") else { continue }
            let request = cloudCodeRequest(url, accessToken: accessToken, body: ["metadata": clientMetadata])
            guard let (status, data) = try? await send(request, in: environment) else {
                try Task.checkCancellation()
                continue
            }
            if status == 401 || status == 403 { throw ProviderFetchError.unauthorized }
            if (200...299).contains(status), let json = object(data) { return try parseCodeAssist(json) }
        }
        return CodeAssist()
    }

    static func parseCodeAssist(_ json: [String: Any]) throws -> CodeAssist {
        let currentTier = json["currentTier"] as? [String: Any]
        let paidTier = json["paidTier"] as? [String: Any]
        let result = CodeAssist(
            project: projectID(json["cloudaicompanionProject"]),
            currentTierID: ProviderJSON.string(currentTier?["id"]),
            currentTierName: ProviderJSON.string(currentTier?["name"]),
            paidTierID: ProviderJSON.string(paidTier?["id"]),
            paidTierName: ProviderJSON.string(paidTier?["name"]),
            planType: ProviderJSON.string((json["planInfo"] as? [String: Any])?["planType"]))
        // Signed in through an OAuth client Cloud Code doesn't onboard: its quota
        // answer would be a placeholder with every pool at 100%.
        let rejected = ((json["ineligibleTiers"] as? [[String: Any]]) ?? []).contains {
            ProviderJSON.string($0["reasonCode"]) == "GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT"
        }
        if rejected, result.currentTierID == nil, result.project == nil {
            throw ProviderFetchError.unsupported(
                "This Antigravity sign-in can't read its quota. Sign in to `agy` again.")
        }
        return result
    }

    private static func projectID(_ value: Any?) -> String? {
        if let id = ProviderJSON.string(value) { return id }
        guard let object = value as? [String: Any] else { return nil }
        return ProviderJSON.string(object["id"]) ?? ProviderJSON.string(object["projectId"])
    }

    static func plan(_ codeAssist: CodeAssist, hostedDomain: String?) -> String? {
        let paidPlans = ["g1-pro-tier": "Pro", "g1-ultra-tier": "Ultra", "g1-ultra-lite-tier": "Ultra Lite"]
        if let id = codeAssist.paidTierID, let plan = paidPlans[id] { return plan }
        if let name = codeAssist.paidTierName { return formatPlan(name) }
        if codeAssist.paidTierID != nil { return "Paid" }
        if let planType = codeAssist.planType { return formatPlan(planType) }
        switch codeAssist.currentTierID {
        case "standard-tier": return "Paid"
        case "free-tier": return hostedDomain == nil ? "Free" : "Workspace"
        case "legacy-tier": return "Legacy"
        default: return codeAssist.currentTierName.map(formatPlan)
        }
    }

    private static func formatPlan(_ raw: String) -> String {
        let lower = raw.lowercased()
        for tier in ["Ultra Lite", "Ultra", "Pro"] where lower.contains(tier.lowercased()) { return tier }
        return raw.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: - Quota summary

    /// The running Antigravity app's own quota summary, the source of its
    /// Usage view: its language server answers on localhost at the port, and
    /// with the CSRF token, it records in `~/.gemini/antigravity/daemon/hub_<port>.json`.
    /// Nil when the app isn't running or doesn't answer.
    static func localSummary(in environment: ProviderEnvironment) async -> Data? {
        let folder = environment.home.appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let hubs = files.filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }
            .sorted { modified($0) > modified($1) }
        for hub in hubs {
            guard let json = ProviderJSON.readObject(at: hub),
                  let port = ProviderJSON.double(json["httpPort"]).map(Int.init), (1...65_535).contains(port),
                  let csrf = ProviderJSON.string(json["csrfToken"]),
                  let pid = ProviderJSON.double(json["pid"]).map(Int32.init), Processes.isRunning(pid),
                  let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
            else { continue }
            var request = ProviderHTTP.request(url, method: "POST", headers: [
                "Connect-Protocol-Version": "1",
                "X-Codeium-Csrf-Token": csrf,
            ], jsonBody: ["forceRefresh": true])
            request.timeoutInterval = 10
            guard let (status, data) = try? await send(request, in: environment), (200...299).contains(status),
                  !buckets(in: data).isEmpty else { continue }
            return data
        }
        return nil
    }

    /// `retrieveUserQuotaSummary` bodies from both hosts. Each counts only the
    /// usage that went through it (production missed the app's Gemini use),
    /// so `windows(fromSummaries:)` keeps the lower of the two.
    static func quotaSummaries(accessToken: String, project: String?,
                               in environment: ProviderEnvironment) async throws -> [Data] {
        let body: [String: Any] = project.map { ["project": $0] } ?? [:]
        var responses: [(status: Int, data: Data)] = []
        var transportError: Error?
        for base in cloudCodeBases {
            guard let url = URL(string: base + "/v1internal:retrieveUserQuotaSummary") else { continue }
            do {
                responses.append(try await send(cloudCodeRequest(url, accessToken: accessToken, body: body), in: environment))
            } catch {
                try Task.checkCancellation()
                transportError = error
            }
        }
        let bodies = responses.filter { (200...299).contains($0.status) }.map(\.data)
        if !bodies.isEmpty { return bodies }
        if responses.isEmpty, let transportError { throw transportError }
        if responses.contains(where: { $0.status == 401 }) { throw ProviderFetchError.unauthorized }
        if responses.contains(where: { $0.status == 403 && errorReasons($0.data).contains("SUBSCRIPTION_REQUIRED") }) {
            throw ProviderFetchError.unsupported(project == nil
                ? "Antigravity found no project with quota access for this account. Try again shortly."
                : "Google reports no Antigravity quota subscription for this account.")
        }
        if responses.contains(where: { $0.status == 403 }) { throw ProviderFetchError.unauthorized }
        throw ProviderFetchError.http(responses.first(where: { $0.status == 429 })?.status ?? responses.first?.status ?? 0)
    }

    struct Bucket: Equatable {
        var id: String
        var group: String?
        var title: String
        var seconds: TimeInterval?
        var fraction: Double
        var resetsAt: Date?
    }

    /// Every bucket in the order the summaries list them, as Antigravity's
    /// Usage view does; one reported by several bodies keeps its lowest share.
    static func windows(fromSummaries bodies: [Data]) -> [ProviderWindow] {
        var order: [String] = []
        var lowest: [String: Bucket] = [:]
        for body in bodies {
            for bucket in buckets(in: body) {
                if let kept = lowest[bucket.id] {
                    if bucket.fraction < kept.fraction { lowest[bucket.id] = bucket }
                } else {
                    order.append(bucket.id)
                    lowest[bucket.id] = bucket
                }
            }
        }
        return order.compactMap { lowest[$0] }.map { bucket in
            ProviderWindow(title: bucket.title, usedPercent: (1 - min(1, max(0, bucket.fraction))) * 100,
                           resetsAt: bucket.resetsAt, windowSeconds: bucket.seconds, group: bucket.group)
        }
    }

    /// Enabled buckets with a known remaining share and something to call
    /// them, titled the way Antigravity's Usage view titles them.
    static func buckets(in data: Data) -> [Bucket] {
        guard let json = object(data) else { return [] }
        let root = (json["response"] as? [String: Any]) ?? (json["summary"] as? [String: Any]) ?? json
        let groups = (root["groups"] as? [[String: Any]]) ?? []
        var result: [Bucket] = []
        for group in groups {
            let groupName = ProviderJSON.string(group["displayName"]) ?? ProviderJSON.string(group["name"])
            for bucket in (group["buckets"] as? [[String: Any]]) ?? [] {
                guard ProviderJSON.bool(bucket["disabled"]) != true,
                      let id = ProviderJSON.string(bucket["bucketId"]) ?? ProviderJSON.string(bucket["id"]),
                      let fraction = remainingFraction(bucket) else { continue }
                let cadence = cadence(window: ProviderJSON.string(bucket["window"]), id: id)
                let title: String
                switch cadence {
                case "5h": title = "5h limit"
                case "weekly": title = "Weekly limit"
                default:
                    guard let name = ProviderJSON.string(bucket["displayName"]) else { continue }
                    title = name.replacingOccurrences(of: " Remaining", with: "")
                }
                result.append(Bucket(
                    id: id, group: groupName, title: title,
                    seconds: cadence == "5h" ? fiveHours : cadence == "weekly" ? week : nil,
                    fraction: fraction, resetsAt: ProviderJSON.date(bucket["resetTime"] ?? bucket["reset_time"])))
            }
        }
        return result
    }

    private static func remainingFraction(_ bucket: [String: Any]) -> Double? {
        if let value = ProviderJSON.double(bucket["remainingFraction"] ?? bucket["remaining_fraction"]) { return value }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
        if let value = ProviderJSON.double(remaining["remainingFraction"]) { return value }
        // Connect's JSON form of a oneof: {"case": "remainingFraction", "value": 0.5}.
        guard ProviderJSON.string(remaining["case"]) == "remainingFraction" else { return nil }
        return ProviderJSON.double(remaining["value"])
    }

    private static func cadence(window: String?, id: String) -> String? {
        switch window?.lowercased() {
        case "5h", "five_hour", "fivehour": return "5h"
        case "weekly", "week", "7d": return "weekly"
        default:
            if id.hasSuffix("-5h") { return "5h" }
            if id.hasSuffix("-weekly") { return "weekly" }
            return nil
        }
    }

    // MARK: - Helpers

    static func userInfoEmail(accessToken: String, in environment: ProviderEnvironment) async -> String? {
        let request = ProviderHTTP.request(userInfoURL, headers: ["Authorization": "Bearer \(accessToken)"])
        guard let json = try? await ProviderHTTP.object(request, in: environment) else { return nil }
        return ProviderJSON.string(json["email"])
    }

    static func cloudCodeRequest(_ url: URL, accessToken: String, body: [String: Any]) -> URLRequest {
        ProviderHTTP.request(url, method: "POST", headers: [
            "Authorization": "Bearer \(accessToken)",
            "User-Agent": userAgent,
        ], jsonBody: body)
    }

    static func errorReasons(_ data: Data) -> [String] {
        let details = ((object(data)?["error"] as? [String: Any])?["details"] as? [[String: Any]]) ?? []
        return details.compactMap { ProviderJSON.string($0["reason"]) }
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func send(_ request: URLRequest, in environment: ProviderEnvironment) async throws -> (status: Int, data: Data) {
        let (data, response) = try await environment.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFetchError.invalidResponse }
        return (http.statusCode, data)
    }
}
