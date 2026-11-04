import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PlatformSupport

/// Gemini CLI's Google sign-in (`~/.gemini/oauth_creds.json`) and its Code
/// Assist quota. An expired access token is renewed with the OAuth client
/// that the installed Gemini CLI ships in `oauth2.js`; the renewed token is
/// kept in memory only, never written back.
public struct GeminiProvider: UsageProvider {
    public let id = "gemini"
    public let name = "Gemini"
    public let brandHex = "#4285F4"
    public let symbol = "sparkle"

    /// Package-manager prefixes searched for an installed Gemini CLI besides
    /// `PATH` and the home directory. Tests clear it.
    var installPrefixes: [String] = ["/opt/homebrew", "/usr/local"]

    public init() {}

    public func isSignedIn(in environment: ProviderEnvironment) -> Bool {
        FileManager.default.fileExists(atPath: Self.credentialsURL(environment).path)
    }

    public func fetch(in environment: ProviderEnvironment) async throws -> ProviderSnapshot {
        try Self.checkAuthType(environment)
        let credentials = try Self.readCredentials(environment)
        let token = try await accessToken(for: credentials, in: environment)
        let claims = ProviderJSON.jwtClaims(token.idToken)
        let hostedDomain = ProviderJSON.string(claims?["hd"])

        let codeAssist = try await Self.loadCodeAssist(
            accessToken: token.accessToken, hostedDomain: hostedDomain, in: environment)
        var project = codeAssist.project
        if project == nil {
            project = await Self.discoverProject(accessToken: token.accessToken, in: environment)
        }
        let buckets = try await Self.retrieveQuota(
            accessToken: token.accessToken, project: project, codeAssist: codeAssist, in: environment)
        let windows = Self.windows(fromBuckets: buckets)
        guard !windows.isEmpty else { throw ProviderFetchError.invalidResponse }
        return ProviderSnapshot(
            account: ProviderJSON.string(claims?["email"]),
            plan: Self.plan(codeAssist, hostedDomain: hostedDomain),
            windows: windows,
            fetchedAt: environment.now())
    }

    // MARK: - Endpoints and copy

    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let projectsURL = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects")!

    static let shutdownMessage =
        "Google no longer serves Gemini CLI quotas to personal, Google AI Pro and Ultra accounts. "
        + "Use Antigravity to see this account's quota."

    // MARK: - Local files

    static func geminiDirectory(_ environment: ProviderEnvironment) -> URL {
        environment.home.appendingPathComponent(".gemini", isDirectory: true)
    }

    static func credentialsURL(_ environment: ProviderEnvironment) -> URL {
        geminiDirectory(environment).appendingPathComponent("oauth_creds.json")
    }

    struct Credentials: Equatable {
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Date?
    }

    static func readCredentials(_ environment: ProviderEnvironment) throws -> Credentials {
        let url = credentialsURL(environment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderFetchError.notSignedIn(
                "No Gemini CLI sign-in found. Run `gemini` in Terminal and choose Sign in with Google.")
        }
        guard let json = ProviderJSON.readObject(at: url) else {
            throw ProviderFetchError.notSignedIn(
                "Gemini CLI's sign-in file couldn't be read. Run `gemini` and sign in with Google again.")
        }
        return Credentials(
            accessToken: ProviderJSON.string(json["access_token"]),
            refreshToken: ProviderJSON.string(json["refresh_token"]),
            idToken: ProviderJSON.string(json["id_token"]),
            expiresAt: ProviderJSON.date(json["expiry_date"]))
    }

    /// API-key and Vertex AI logins have no per-account quota to show.
    static func checkAuthType(_ environment: ProviderEnvironment) throws {
        let url = geminiDirectory(environment).appendingPathComponent("settings.json")
        guard let settings = ProviderJSON.readObject(at: url) else { return }
        let auth = (settings["security"] as? [String: Any])?["auth"] as? [String: Any]
        let selected = ProviderJSON.string(auth?["selectedType"]) ?? ProviderJSON.string(settings["selectedAuthType"])
        switch selected {
        case "gemini-api-key", "api-key":
            throw ProviderFetchError.unsupported(
                "Gemini CLI is set to use an API key. Only a Google sign-in has a quota to show.")
        case "vertex-ai":
            throw ProviderFetchError.unsupported(
                "Gemini CLI is set to use Vertex AI. Only a Google sign-in has a quota to show.")
        default:
            return
        }
    }

    // MARK: - Access token

    private struct CachedToken: Sendable {
        var accessToken: String
        var idToken: String?
        var expiresAt: Date
    }

    /// Tokens renewed in this process, by refresh token. Never persisted.
    private static let renewedTokens = LockedValue<[String: CachedToken]>([:])

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
        guard let client = oauthClient(in: environment) else {
            throw ProviderFetchError.notSignedIn(
                "Gemini CLI's sign-in has expired and its OAuth client wasn't found to renew it. "
                    + "Run `gemini` once to refresh the sign-in, or update Gemini CLI.")
        }
        let request = ProviderHTTP.request(Self.tokenURL, method: "POST", formBody: [
            "client_id": client.id,
            "client_secret": client.secret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        let (status, data) = try await Self.send(request, in: environment)
        guard (200...299).contains(status) else {
            if Self.isShutdownSignal(data) { throw ProviderFetchError.unsupported(Self.shutdownMessage) }
            if status >= 500 { throw ProviderFetchError.http(status) }
            throw ProviderFetchError.unauthorized
        }
        guard let json = Self.object(data), let accessToken = ProviderJSON.string(json["access_token"]) else {
            throw ProviderFetchError.invalidResponse
        }
        let renewed = CachedToken(
            accessToken: accessToken,
            idToken: ProviderJSON.string(json["id_token"]),
            expiresAt: now.addingTimeInterval(ProviderJSON.double(json["expires_in"]) ?? 3600))
        Self.renewedTokens.withLock { $0[refreshToken] = renewed }
        return (accessToken, renewed.idToken ?? credentials.idToken)
    }

    // MARK: - OAuth client (from the installed Gemini CLI)

    struct OAuthClient: Equatable, Sendable {
        var id: String
        var secret: String
    }

    /// `GEMINI_OAUTH_CLIENT_ID` + `GEMINI_OAUTH_CLIENT_SECRET`, then
    /// `GEMINI_OAUTH2_JS_PATH`, then the `oauth2.js` (or bundle) of an
    /// installed Gemini CLI.
    func oauthClient(in environment: ProviderEnvironment) -> OAuthClient? {
        let variables = environment.variables
        if let id = ProviderJSON.string(variables["GEMINI_OAUTH_CLIENT_ID"]),
           let secret = ProviderJSON.string(variables["GEMINI_OAUTH_CLIENT_SECRET"]) {
            return OAuthClient(id: id, secret: secret)
        }
        if let path = ProviderJSON.string(variables["GEMINI_OAUTH2_JS_PATH"]),
           let client = Self.parseClient(file: URL(fileURLWithPath: path)) {
            return client
        }
        for root in packageRoots(in: environment) {
            if let client = Self.client(inPackage: root) { return client }
        }
        return nil
    }

    /// Install roots of `@google/gemini-cli` (or `gemini-cli-core`), from the
    /// `gemini` executables on `PATH` and the usual global install layouts.
    func packageRoots(in environment: ProviderEnvironment) -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let url = url.standardizedFileURL
            guard seen.insert(url.path).inserted, fileManager.fileExists(atPath: url.path) else { return }
            roots.append(url)
        }

        let home = environment.home
        var binDirectories = (environment.variables["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        binDirectories += [".npm-global/bin", ".local/bin", ".bun/bin", ".volta/bin", ".yarn/bin"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        binDirectories += installPrefixes.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("bin") }
        for directory in binDirectories {
            let executable = directory.appendingPathComponent("gemini")
            guard fileManager.fileExists(atPath: executable.path),
                  let root = Self.packageRoot(above: executable.resolvingSymlinksInPath()) else { continue }
            add(root)
        }

        let prefixes = installPrefixes.map { URL(fileURLWithPath: $0, isDirectory: true) }
            + [home.appendingPathComponent(".npm-global", isDirectory: true)]
        for prefix in prefixes {
            let modules = prefix.appendingPathComponent("lib/node_modules/@google", isDirectory: true)
            add(modules.appendingPathComponent("gemini-cli"))
            add(modules.appendingPathComponent("gemini-cli-core"))
            add(prefix.appendingPathComponent("opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli"))
            let cellar = prefix.appendingPathComponent("Cellar/gemini-cli", isDirectory: true)
            for version in ((try? fileManager.contentsOfDirectory(atPath: cellar.path)) ?? []).sorted().reversed() {
                add(cellar.appendingPathComponent(version).appendingPathComponent("libexec/lib/node_modules/@google/gemini-cli"))
            }
        }
        return roots
    }

    /// The `@google/gemini-cli` package an executable belongs to, found by
    /// walking up from it (npm, Bun and Homebrew layouts).
    static func packageRoot(above executable: URL) -> URL? {
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<9 {
            let candidates = [
                directory,
                directory.appendingPathComponent("lib/node_modules/@google/gemini-cli"),
                directory.appendingPathComponent("libexec/lib/node_modules/@google/gemini-cli"),
            ]
            for candidate in candidates where isGeminiPackage(candidate) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private static func isGeminiPackage(_ directory: URL) -> Bool {
        let manifest = ProviderJSON.readObject(at: directory.appendingPathComponent("package.json"))
        return ProviderJSON.string(manifest?["name"]) == "@google/gemini-cli"
    }

    static func client(inPackage root: URL) -> OAuthClient? {
        let oauthFile = "dist/src/code_assist/oauth2.js"
        let files = [
            root.appendingPathComponent(oauthFile),
            root.appendingPathComponent("node_modules/@google/gemini-cli-core").appendingPathComponent(oauthFile),
            root.deletingLastPathComponent().appendingPathComponent("gemini-cli-core").appendingPathComponent(oauthFile),
        ]
        for file in files {
            if let client = parseClient(file: file) { return client }
        }
        // Bundled releases inline the core package into `bundle/*.js`.
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        let chunks = ((try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? [])
            .filter { $0.hasSuffix(".js") && $0 != "gemini.js" }
            .sorted()
        for name in ["gemini.js"] + chunks {
            if let client = parseClient(file: bundle.appendingPathComponent(name)) { return client }
        }
        return nil
    }

    static func parseClient(file: URL) -> OAuthClient? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parseClient(text: text)
    }

    static func parseClient(text: String) -> OAuthClient? {
        guard text.contains("OAUTH_CLIENT_SECRET"),
              let id = firstMatch(#"OAUTH_CLIENT_ID\s*=\s*['"]([\w.\-]+)['"]"#, in: text),
              let secret = firstMatch(#"OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]"#, in: text)
        else { return nil }
        return OAuthClient(id: id, secret: secret)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - Code Assist

    struct CodeAssist: Equatable {
        var tier: String?
        var project: String?
        var paidTierName: String?
        /// Google listed this client as unsupported for the account's consumer
        /// tier (the June 2026 shutdown) and nothing says the account is exempt.
        var consumerClientUnsupported = false
    }

    static func loadCodeAssist(accessToken: String, hostedDomain: String?,
                               in environment: ProviderEnvironment) async throws -> CodeAssist {
        let request = ProviderHTTP.request(
            loadCodeAssistURL, method: "POST",
            headers: ["Authorization": "Bearer \(accessToken)"],
            jsonBody: ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]])
        let status: Int
        let data: Data
        do {
            (status, data) = try await send(request, in: environment)
        } catch {
            try Task.checkCancellation()
            return CodeAssist() // Tier and project are best effort; the quota call reports real failures.
        }
        guard (200...299).contains(status) else {
            if isShutdownSignal(data) { throw ProviderFetchError.unsupported(shutdownMessage) }
            if status == 401 { throw ProviderFetchError.unauthorized }
            return CodeAssist()
        }
        guard let json = object(data) else { return CodeAssist() }
        return try parseCodeAssist(json, hostedDomain: hostedDomain)
    }

    static func parseCodeAssist(_ json: [String: Any], hostedDomain: String?) throws -> CodeAssist {
        var status = CodeAssist()
        status.project = projectID(json["cloudaicompanionProject"])
        status.tier = ProviderJSON.string((json["currentTier"] as? [String: Any])?["id"])
        status.paidTierName = ProviderJSON.string((json["paidTier"] as? [String: Any])?["name"])
        let flagged = ((json["ineligibleTiers"] as? [[String: Any]]) ?? []).contains { entry in
            [entry["reasonCode"], entry["reasonMessage"]].compactMap { $0 as? String }.contains(where: isShutdownSignal)
        }
        // A named paid tier or a Workspace/education domain is outside the shutdown.
        status.consumerClientUnsupported = flagged && status.paidTierName == nil && hostedDomain == nil
        if status.tier == nil, status.consumerClientUnsupported {
            throw ProviderFetchError.unsupported(shutdownMessage)
        }
        return status
    }

    private static func projectID(_ value: Any?) -> String? {
        if let id = ProviderJSON.string(value) { return id }
        guard let object = value as? [String: Any] else { return nil }
        return ProviderJSON.string(object["id"]) ?? ProviderJSON.string(object["projectId"])
    }

    /// The user's own Gemini API project when Code Assist names none.
    static func discoverProject(accessToken: String, in environment: ProviderEnvironment) async -> String? {
        let request = ProviderHTTP.request(projectsURL, headers: ["Authorization": "Bearer \(accessToken)"])
        guard let json = try? await ProviderHTTP.object(request, in: environment),
              let projects = json["projects"] as? [[String: Any]] else { return nil }
        for project in projects {
            guard let id = ProviderJSON.string(project["projectId"]) else { continue }
            if id.hasPrefix("gen-lang-client") { return id }
            if let labels = project["labels"] as? [String: Any], labels["generative-language"] != nil { return id }
        }
        return nil
    }

    // MARK: - Quota

    static func retrieveQuota(accessToken: String, project: String?, codeAssist: CodeAssist,
                              in environment: ProviderEnvironment) async throws -> [[String: Any]] {
        let body: [String: Any] = project.map { ["project": $0] } ?? [:]
        let request = ProviderHTTP.request(
            quotaURL, method: "POST", headers: ["Authorization": "Bearer \(accessToken)"], jsonBody: body)
        let (status, data) = try await send(request, in: environment)
        guard (200...299).contains(status) else {
            if isShutdownSignal(data) { throw ProviderFetchError.unsupported(shutdownMessage) }
            switch status {
            case 401:
                throw ProviderFetchError.unauthorized
            case 403:
                // Google's shutdown answers the quota call with a bare 403
                // SUBSCRIPTION_REQUIRED; only read it as the shutdown when
                // Code Assist flagged this client and the account is unlicensed.
                if codeAssist.consumerClientUnsupported, codeAssist.tier != "standard-tier" {
                    throw ProviderFetchError.unsupported(shutdownMessage)
                }
                if errorReasons(data).contains("SUBSCRIPTION_REQUIRED") {
                    throw ProviderFetchError.unsupported("Google reports no Gemini Code Assist license for this account.")
                }
                throw ProviderFetchError.unauthorized
            default:
                throw ProviderFetchError.http(status)
            }
        }
        guard let json = object(data), let buckets = json["buckets"] as? [[String: Any]] else {
            throw ProviderFetchError.invalidResponse
        }
        return buckets
    }

    /// Lowest remaining share per model, then per family: Pro, Flash, Flash Lite.
    static func windows(fromBuckets buckets: [[String: Any]]) -> [ProviderWindow] {
        var lowest: [String: (fraction: Double, resetsAt: Date?)] = [:]
        for bucket in buckets {
            guard let model = ProviderJSON.string(bucket["modelId"])?.lowercased(),
                  let fraction = ProviderJSON.double(bucket["remainingFraction"]) else { continue }
            if let existing = lowest[model], existing.fraction <= fraction { continue }
            lowest[model] = (fraction, ProviderJSON.date(bucket["resetTime"]))
        }
        let models = lowest.sorted { $0.key < $1.key }
        func window(_ title: String, _ matches: (String) -> Bool) -> ProviderWindow? {
            guard let entry = models.filter({ matches($0.key) }).min(by: { $0.value.fraction < $1.value.fraction })?.value
            else { return nil }
            let remaining = min(1, max(0, entry.fraction))
            return ProviderWindow(title: title, usedPercent: (1 - remaining) * 100,
                                  resetsAt: entry.resetsAt, windowSeconds: 86_400)
        }
        let isLite = { (model: String) in model.contains("flash-lite") }
        var windows = [
            window("Pro models") { $0.contains("pro") },
            window("Flash") { $0.contains("flash") && !isLite($0) },
            window("Flash Lite", isLite),
        ].compactMap { $0 }
        if windows.isEmpty, let any = window("Quota", { _ in true }) {
            windows = [any]
        }
        return windows
    }

    static func plan(_ codeAssist: CodeAssist, hostedDomain: String?) -> String? {
        if let name = codeAssist.paidTierName { return name }
        switch codeAssist.tier {
        case "standard-tier": return "Paid"
        case "free-tier": return hostedDomain == nil ? "Free" : "Workspace"
        case "legacy-tier": return "Legacy"
        default: return nil
        }
    }

    // MARK: - Helpers

    /// Google's consumer-tier shutdown wording (June 2026).
    static func isShutdownSignal(_ text: String) -> Bool {
        let text = text.lowercased()
        return text.contains("unsupported_client")
            || text.contains("ineligibletiererror")
            || (text.contains("no longer supported") && text.contains("gemini code assist"))
            || (text.contains("migrate") && text.contains("antigravity") && text.contains("gemini"))
    }

    static func isShutdownSignal(_ data: Data) -> Bool {
        isShutdownSignal(String(decoding: data, as: UTF8.self))
    }

    /// `error.details[].reason` of a Google API error body.
    static func errorReasons(_ data: Data) -> [String] {
        let details = ((object(data)?["error"] as? [String: Any])?["details"] as? [[String: Any]]) ?? []
        return details.compactMap { ProviderJSON.string($0["reason"]) }
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One request, status and body as they came (Google's error bodies carry
    /// the reasons this provider maps).
    static func send(_ request: URLRequest, in environment: ProviderEnvironment) async throws -> (Int, Data) {
        let (data, response) = try await environment.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderFetchError.invalidResponse }
        return (http.statusCode, data)
    }
}
