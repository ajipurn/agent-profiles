import Foundation
import Testing
import PlatformSupport
@testable import ProvidersCore

/// The Keychain, in memory.
private final class MemoryVault: SignInVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    var failWrites = false

    private func key(_ service: String, _ account: String) -> String { service + "\u{0}" + account }

    func stored(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[key(service, account)]
    }

    func set(_ stored: String, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw GoKeyring.KeychainError.writeFailed }
        items[key(service, account)] = stored
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key(service, account)] = nil
    }

    var live: String? {
        get { stored(service: AntigravityAccounts.liveService, account: AntigravityAccounts.liveAccount) }
        set {
            if let newValue {
                try? set(newValue, service: AntigravityAccounts.liveService, account: AntigravityAccounts.liveAccount)
            } else {
                try? delete(service: AntigravityAccounts.liveService, account: AntigravityAccounts.liveAccount)
            }
        }
    }
}

/// Antigravity, as far as switching sees it.
private final class FakeApp: AntigravityAppControl, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private(set) var events: [String] = []
    var refusesToQuit = false
    var installed = true
    /// Runs as the app quits, as Antigravity writing its sign-in on the way out.
    var onQuit: (() -> Void)?

    init(running: Bool) { self.running = running }

    private func record(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func isInstalled() async -> Bool { installed }

    func isRunning() async -> Bool {
        lock.withLock { running }
    }

    func quit() async -> Bool {
        record("quit")
        guard !refusesToQuit else { return false }
        onQuit?()
        lock.withLock { running = false }
        return true
    }

    func launch(activate: Bool) async {
        record(activate ? "launch in front" : "launch")
        lock.withLock { running = true }
    }
}

/// A stored sign-in as Antigravity writes it, for `email`.
private func signIn(_ email: String, access: String = "ya29.access", refresh: String? = nil) -> String {
    let json: [String: Any] = [
        "token": ["access_token": access, "refresh_token": refresh ?? "1//refresh-\(email)",
                  "expiry": "2026-11-10T10:00:00.123456789+07:00", "token_type": "Bearer"],
        "auth_method": "consumer",
        "id_token_email": email,
    ]
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    return GoKeyring.encode(String(decoding: data, as: UTF8.self))
}

private struct Sandbox {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("antigravity-accounts-\(UUID().uuidString)")
    let vault = MemoryVault()
    var accounts: AntigravityAccounts { AntigravityAccounts(folder: folder, vault: vault) }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    func saved(_ account: AntigravityAccount) -> String? {
        vault.stored(service: AntigravityAccounts.savedService, account: account.id.uuidString)
    }
}

@Suite struct AntigravityAccountsTests {
    @Test func savesTheSignInByItsAccount() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let accounts = sandbox.accounts
        #expect(try accounts.saveLive() == nil)

        sandbox.vault.live = signIn("one@example.com")
        let first = try #require(try accounts.saveLive())
        #expect(first.email == "one@example.com")
        #expect(sandbox.saved(first) == sandbox.vault.live)

        // Antigravity renewed its token: same account, newer copy.
        sandbox.vault.live = signIn("ONE@example.com", access: "ya29.renewed")
        let again = try #require(try accounts.saveLive())
        #expect(again.id == first.id)
        #expect(accounts.list().map(\.email) == ["one@example.com"])
        #expect(accounts.signIn(first.id)?.contains("ya29.renewed") == true)
        // The list holds no tokens.
        let list = try String(contentsOf: accounts.listURL, encoding: .utf8)
        #expect(!list.contains("ya29") && !list.contains("refresh"))
    }

    @Test func readsTheAccountFromTheIDTokenToo() {
        let claims = Data(#"{"email":"jwt@example.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let json = #"{"token":{"access_token":"a"},"id_token":"e30.\#(claims).sig"}"#
        #expect(AntigravityAccounts.email(ofStored: json) == "jwt@example.com")
        #expect(AntigravityAccounts.email(ofStored: GoKeyring.encode(json)) == "jwt@example.com")
        #expect(AntigravityAccounts.email(ofStored: #"{"token":{"access_token":"a"}}"#) == nil)
        #expect(AntigravityAccounts.email(ofStored: "not json") == nil)
    }

    @Test func aSignInWithoutAnAccountIsNotSaved() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        sandbox.vault.live = GoKeyring.encode(#"{"token":{"access_token":"a"}}"#)
        #expect(throws: AntigravityAccountError.unknownSignIn) { try sandbox.accounts.saveLive() }
        #expect(sandbox.accounts.list().isEmpty)
    }

    @Test func switchingSwapsTheSignInAndReopensAntigravity() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let accounts = sandbox.accounts
        sandbox.vault.live = signIn("two@example.com")
        let two = try #require(try accounts.saveLive())
        sandbox.vault.live = signIn("one@example.com")
        let one = try #require(try accounts.saveLive())
        let app = FakeApp(running: true)
        // Antigravity renews its token as it quits; that copy must be kept.
        app.onQuit = { sandbox.vault.live = signIn("one@example.com", access: "ya29.on-quit") }

        try await accounts.switchTo(two.id, app: app)

        #expect(accounts.liveEmail() == "two@example.com")
        #expect(app.events == ["quit", "launch"])
        #expect(accounts.signIn(one.id)?.contains("ya29.on-quit") == true)
        #expect(await app.isRunning())
    }

    @Test func switchingWhileAntigravityIsClosedLeavesItClosed() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let accounts = sandbox.accounts
        sandbox.vault.live = signIn("two@example.com")
        let two = try #require(try accounts.saveLive())
        sandbox.vault.live = signIn("one@example.com")
        _ = try accounts.saveLive()
        let app = FakeApp(running: false)

        try await accounts.switchTo(two.id, app: app)

        #expect(accounts.liveEmail() == "two@example.com")
        #expect(app.events == ["quit"])
    }

    @Test func switchingToTheSignedInAccountDoesNothing() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        sandbox.vault.live = signIn("one@example.com")
        let one = try #require(try sandbox.accounts.saveLive())
        let app = FakeApp(running: true)

        try await sandbox.accounts.switchTo(one.id, app: app)

        #expect(app.events.isEmpty)
    }

    @Test func anAppThatWontQuitKeepsItsSignIn() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let accounts = sandbox.accounts
        sandbox.vault.live = signIn("two@example.com")
        let two = try #require(try accounts.saveLive())
        sandbox.vault.live = signIn("one@example.com")
        let app = FakeApp(running: true)
        app.refusesToQuit = true

        await #expect(throws: AntigravityAccountError.appStillRunning) { try await accounts.switchTo(two.id, app: app) }
        #expect(accounts.liveEmail() == "one@example.com")
    }

    @Test func aFailedWriteReopensAntigravityAsItWas() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let accounts = sandbox.accounts
        sandbox.vault.live = signIn("two@example.com")
        let two = try #require(try accounts.saveLive())
        sandbox.vault.live = signIn("one@example.com")
        _ = try accounts.saveLive()
        let app = FakeApp(running: true)
        sandbox.vault.failWrites = true

        await #expect(throws: GoKeyring.KeychainError.writeFailed) { try await accounts.switchTo(two.id, app: app) }
        #expect(accounts.liveEmail() == "one@example.com")
        #expect(app.events == ["quit", "launch"])
    }

    @Test func switchingToAForgottenAccountFails() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let accounts = sandbox.accounts
        sandbox.vault.live = signIn("two@example.com")
        let two = try #require(try accounts.saveLive())
        sandbox.vault.live = signIn("one@example.com")
        try accounts.remove(two.id)
        #expect(sandbox.saved(two) == nil)
        let app = FakeApp(running: true)

        await #expect(throws: AntigravityAccountError.unknownAccount) { try await accounts.switchTo(two.id, app: app) }
        #expect(app.events.isEmpty)
    }

    @Test func addingSignsOutLocallyAndSavesWhoSignsIn() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let accounts = sandbox.accounts
        sandbox.vault.live = signIn("one@example.com")
        let app = FakeApp(running: true)

        let previous = try await accounts.beginAdding(app: app)

        #expect(previous?.email == "one@example.com")
        #expect(sandbox.vault.live == nil)
        #expect(app.events == ["quit", "launch in front"])
        #expect(accounts.finishAdding() == nil)

        sandbox.vault.live = signIn("two@example.com")
        let added = try #require(accounts.finishAdding())
        #expect(added.email == "two@example.com")
        #expect(accounts.list().map(\.email) == ["one@example.com", "two@example.com"])
    }

    @Test func addingNeedsTheApp() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        sandbox.vault.live = signIn("one@example.com")
        let app = FakeApp(running: false)
        app.installed = false

        await #expect(throws: AntigravityAccountError.appMissing) { try await sandbox.accounts.beginAdding(app: app) }
        #expect(sandbox.accounts.liveEmail() == "one@example.com")
        #expect(app.events.isEmpty)
    }

    @Test func cancellingAddingSignsThePreviousAccountInAgain() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let accounts = sandbox.accounts
        sandbox.vault.live = signIn("one@example.com")
        let app = FakeApp(running: true)
        let previous = try await accounts.beginAdding(app: app)

        try await accounts.cancelAdding(restoring: previous?.id, app: app)

        #expect(accounts.liveEmail() == "one@example.com")
        #expect(app.events == ["quit", "launch in front", "quit", "launch"])
    }

    @Test func cancellingAfterASignInKeepsIt() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let accounts = sandbox.accounts
        sandbox.vault.live = signIn("one@example.com")
        let app = FakeApp(running: true)
        let previous = try await accounts.beginAdding(app: app)
        sandbox.vault.live = signIn("two@example.com")

        try await accounts.cancelAdding(restoring: previous?.id, app: app)

        #expect(accounts.liveEmail() == "two@example.com")
        #expect(accounts.list().map(\.email) == ["one@example.com", "two@example.com"])
        #expect(app.events == ["quit", "launch in front"])
    }
}
