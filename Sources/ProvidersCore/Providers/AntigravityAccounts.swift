import Foundation
import PlatformSupport

/// A saved Antigravity sign-in, known by its Google account.
public struct AntigravityAccount: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var email: String
    public var addedAt: Date

    public init(id: UUID = UUID(), email: String, addedAt: Date = Date()) {
        self.id = id
        self.email = email
        self.addedAt = addedAt
    }

    /// Whether `query` names this account: its email, ignoring case. The URL
    /// scheme switches by it.
    public func matches(_ query: String) -> Bool {
        !query.isEmpty && email.caseInsensitiveCompare(query) == .orderedSame
    }
}

/// Keychain items in their stored form, by service and account.
public protocol SignInVault: Sendable {
    func stored(service: String, account: String) -> String?
    func set(_ stored: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// The login Keychain, through `/usr/bin/security` as go-keyring uses it.
public struct LoginKeychain: SignInVault {
    public init() {}

    public func stored(service: String, account: String) -> String? {
        GoKeyring.stored(service: service, account: account)
    }

    public func set(_ stored: String, service: String, account: String) throws {
        try GoKeyring.set(stored, service: service, account: account)
    }

    public func delete(service: String, account: String) throws {
        try GoKeyring.delete(service: service, account: account)
    }
}

/// The Antigravity app, quit and opened again around a change of sign-in.
public protocol AntigravityAppControl: Sendable {
    func isInstalled() async -> Bool
    func isRunning() async -> Bool
    /// Quits the app and waits for its processes, the language server that
    /// writes the sign-in among them, to end. False when they didn't.
    func quit() async -> Bool
    func launch(activate: Bool) async
}

public enum AntigravityAccountError: Error, Equatable, LocalizedError {
    case unknownAccount, unknownSignIn, appStillRunning, appMissing

    public var errorDescription: String? {
        switch self {
        case .unknownAccount: "That Antigravity account isn't saved any more."
        case .unknownSignIn: "Antigravity's sign-in doesn't say which Google account it belongs to."
        case .appStillRunning: "Antigravity didn't quit, so its sign-in was left as it was."
        case .appMissing: "The Antigravity app isn't installed, so there is nowhere to sign in."
        }
    }
}

/// Several Google accounts for Antigravity on one Mac, switched the way
/// Codex accounts are. Antigravity (the app and `agy`) keeps one sign-in, in
/// the login Keychain item `gemini` / `antigravity`. Each saved account is a
/// copy of that item in one of ours (service `Agent Profiles Antigravity`,
/// account = the saved account's id), written through `/usr/bin/security`
/// like Antigravity's own, so neither prompts. `accounts.json` in the app's
/// data folder lists the saved accounts: ids and emails, no tokens.
///
/// Switching quits Antigravity, saves the sign-in it had (Antigravity may
/// have renewed it), writes the chosen copy into its item and opens it
/// again if it was open. Adding an account saves the current one, removes
/// Antigravity's item while it is closed and opens it on its sign-in
/// screen; Antigravity's own Sign Out is never used, so no saved sign-in is
/// revoked.
public struct AntigravityAccounts: Sendable {
    public static let liveService = AntigravityProvider.keychainService
    public static let liveAccount = AntigravityProvider.keychainAccount
    public static let savedService = "Agent Profiles Antigravity"

    public let folder: URL
    public let vault: any SignInVault
    /// Saving reads, then rewrites the list: one at a time, or two saves of
    /// a new account (the panel's poll and a refresh) would both add it.
    private static let listLock = LockedValue(())
    /// Accounts found for sign-ins that don't name theirs, by refresh token.
    private static let knownEmails = LockedValue<[String: String]>([:])

    /// Asks Google which account a sign-in (its stored JSON) belongs to.
    public typealias EmailLookup = @Sendable (String) async -> String?
    let lookUpEmail: EmailLookup

    public init(folder: URL, vault: any SignInVault = LoginKeychain(), lookUpEmail: EmailLookup? = nil) {
        self.folder = folder
        self.vault = vault
        self.lookUpEmail = lookUpEmail ?? { signIn in
            await AntigravityProvider.lookUpEmail(signIn: signIn, in: ProviderEnvironment())
        }
    }

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AntigravityAccounts {
        AntigravityAccounts(folder: PlatformPaths.appData(home: home)
            .appendingPathComponent("AgentProfiles/Antigravity", isDirectory: true))
    }

    var listURL: URL { folder.appendingPathComponent("accounts.json") }

    // MARK: Saved accounts

    /// Saved accounts, oldest first.
    public func list() -> [AntigravityAccount] {
        guard let data = try? Data(contentsOf: listURL),
              let accounts = try? Self.decoder.decode([AntigravityAccount].self, from: data) else { return [] }
        return accounts
    }

    func write(_ accounts: [AntigravityAccount]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(accounts).write(to: listURL, options: .atomic)
    }

    /// A saved account's sign-in, decoded: the JSON Antigravity stores.
    public func signIn(_ id: UUID) -> String? {
        vault.stored(service: Self.savedService, account: id.uuidString).flatMap(GoKeyring.decode)
    }

    /// Forgets a saved account. Antigravity's own sign-in stays as it is.
    public func remove(_ id: UUID) throws {
        try Self.listLock.withLock { _ in
            try vault.delete(service: Self.savedService, account: id.uuidString)
            try write(list().filter { $0.id != id })
        }
    }

    // MARK: Antigravity's sign-in

    /// Antigravity's sign-in as stored, or nil when it is signed out.
    public func liveStored() -> String? {
        vault.stored(service: Self.liveService, account: Self.liveAccount)
    }

    /// The Google account Antigravity is signed in with.
    public func liveEmail() async -> String? {
        guard let stored = liveStored() else { return nil }
        return await email(of: stored)
    }

    /// The account a stored sign-in names: `id_token_email`, which
    /// Antigravity adds beside the token at some point, else the ID token's
    /// claim. A fresh sign-in has neither.
    public static func email(ofStored stored: String) -> String? {
        guard let json = GoKeyring.decode(stored).flatMap({ AntigravityProvider.object(Data($0.utf8)) }) else {
            return nil
        }
        let credentials = AntigravityProvider.credentials(json)
        return validEmail(credentials.email ?? ProviderJSON.string(ProviderJSON.jwtClaims(credentials.idToken)?["email"]))
    }

    /// The account a stored sign-in belongs to. When it doesn't say: the
    /// saved account with the same refresh token, else Google, asked once
    /// per refresh token.
    func email(of stored: String) async -> String? {
        if let email = Self.email(ofStored: stored) { return email }
        guard let signIn = GoKeyring.decode(stored), let refreshToken = Self.refreshToken(signIn) else { return nil }
        if let known = Self.knownEmails.withLock({ $0[refreshToken] }) { return known }
        var email = Self.validEmail(list().first { Self.refreshToken(self.signIn($0.id)) == refreshToken }?.email)
        if email == nil { email = Self.validEmail(await lookUpEmail(signIn)) }
        guard let email else { return nil }
        Self.knownEmails.withLock { $0[refreshToken] = email }
        return email
    }

    static func refreshToken(_ signIn: String?) -> String? {
        guard let signIn, let json = AntigravityProvider.object(Data(signIn.utf8)) else { return nil }
        return AntigravityProvider.credentials(json).refreshToken
    }

    static func validEmail(_ value: String?) -> String? {
        guard let email = value?.trimmingCharacters(in: .whitespaces),
              let at = email.firstIndex(of: "@"), at != email.startIndex,
              email[email.index(after: at)...].contains(".") else { return nil }
        return email
    }

    /// Saves Antigravity's sign-in: refreshes its account's copy, or adds
    /// the account. Nil when Antigravity is signed out.
    @discardableResult
    public func saveLive() async throws -> AntigravityAccount? {
        guard let stored = liveStored() else { return nil }
        guard let email = await email(of: stored), let password = GoKeyring.decode(stored) else {
            throw AntigravityAccountError.unknownSignIn
        }
        return try Self.listLock.withLock { _ in
            var accounts = list()
            let account = accounts.first { $0.matches(email) } ?? AntigravityAccount(email: email)
            // go-keyring's base64 form, which every field-safe check passes.
            try vault.set(GoKeyring.encode(password), service: Self.savedService, account: account.id.uuidString)
            if !accounts.contains(where: { $0.id == account.id }) {
                accounts.append(account)
                try write(accounts)
            }
            return account
        }
    }

    // MARK: Switching

    /// Signs Antigravity in with a saved account.
    public func switchTo(_ id: UUID, app: any AntigravityAppControl) async throws {
        guard let account = list().first(where: { $0.id == id }),
              vault.stored(service: Self.savedService, account: id.uuidString) != nil else {
            throw AntigravityAccountError.unknownAccount
        }
        if let live = await liveEmail(), account.matches(live) { return }
        let wasRunning = await app.isRunning()
        guard await app.quit() else { throw AntigravityAccountError.appStillRunning }
        do {
            let previous = liveStored()
            _ = try await saveLive()
            guard let target = vault.stored(service: Self.savedService, account: id.uuidString) else {
                throw AntigravityAccountError.unknownAccount
            }
            do {
                try vault.set(target, service: Self.liveService, account: Self.liveAccount)
            } catch {
                if let previous { try? vault.set(previous, service: Self.liveService, account: Self.liveAccount) }
                throw error
            }
        } catch {
            if wasRunning { await app.launch(activate: false) }
            throw error
        }
        if wasRunning { await app.launch(activate: false) }
    }

    /// Readies Antigravity for another account: saves its sign-in, quits it,
    /// removes the sign-in and opens it on its sign-in screen. Returns the
    /// account that was signed in, to put back if adding is cancelled.
    public func beginAdding(app: any AntigravityAppControl) async throws -> AntigravityAccount? {
        guard await app.isInstalled() else { throw AntigravityAccountError.appMissing }
        guard await app.quit() else { throw AntigravityAccountError.appStillRunning }
        let previous: AntigravityAccount?
        do {
            previous = try await saveLive()
            try vault.delete(service: Self.liveService, account: Self.liveAccount)
        } catch {
            await app.launch(activate: false)
            throw error
        }
        await app.launch(activate: true)
        return previous
    }

    /// The account signed in since `beginAdding`, now saved; nil while
    /// Antigravity is still signed out or has only part of its sign-in.
    public func finishAdding() async -> AntigravityAccount? {
        try? await saveLive()
    }

    /// Gives up on adding an account: whatever signed in meanwhile is kept
    /// (and saved); otherwise `previous` is signed in again.
    public func cancelAdding(restoring previous: UUID?, app: any AntigravityAppControl) async throws {
        if liveStored() != nil {
            _ = try? await saveLive()
            return
        }
        guard let previous, let stored = vault.stored(service: Self.savedService, account: previous.uuidString) else {
            return
        }
        let wasRunning = await app.isRunning()
        guard await app.quit() else { throw AntigravityAccountError.appStillRunning }
        // Antigravity may have finished a sign-in while it was quitting.
        if liveStored() == nil {
            try vault.set(stored, service: Self.liveService, account: Self.liveAccount)
        } else {
            _ = try? await saveLive()
        }
        if wasRunning { await app.launch(activate: false) }
    }

    // MARK: JSON

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
