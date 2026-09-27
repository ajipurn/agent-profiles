import Foundation

public struct AccountSwitcher: Sendable {
    public var paths: CodexPaths
    public var clients: any CodexClientController
    public var store: ProfileStore

    public init(paths: CodexPaths, clients: any CodexClientController) {
        self.paths = paths
        self.clients = clients
        self.store = ProfileStore(paths: paths)
    }

    public func liveState() throws -> LiveState {
        let file = try readLiveFile()
        let matching = try file.flatMap { try store.profileMatching($0) }
        return LiveState(file: file, matchingProfileID: matching?.id)
    }

    public func profiles() throws -> [Profile] {
        try store.list()
    }

    @discardableResult
    public func saveCurrent(name: String) throws -> Profile {
        guard let live = try readLiveFile() else { throw SwitcherError.missingAuthFile }
        return try store.save(name: name, snapshot: live)
    }

    public func switchTo(_ id: UUID, restartChatGPT restartOverride: Bool? = nil) async throws {
        let target = try store.loadSnapshot(id)
        let settings = store.loadSettings()
        let shouldRestart = restartOverride ?? settings.restartChatGPT
        try persistLiveIntoMatchingProfile()
        let previousFile = try readLiveFile()
        await clients.stopForSwitch(
            restartChatGPT: shouldRestart,
            restartEditorServer: false
        )
        do {
            try writeLiveFile(target)
        } catch {
            if let previousFile {
                try? writeLiveFile(previousFile)
            }
            await clients.startAfterSwitch(restartChatGPT: shouldRestart)
            throw error
        }
        await clients.startAfterSwitch(restartChatGPT: shouldRestart)
    }

    public func rename(_ id: UUID, to name: String) throws -> Profile {
        try store.rename(id, to: name)
    }

    public func delete(_ id: UUID) throws {
        try store.delete(id)
    }

    public func suggestedName(for snapshot: AuthSnapshot? = nil) throws -> String {
        let live = try snapshot ?? readLiveFile()
        guard let identity = live?.identity else { return "Account" }
        if let email = identity.email, !email.isEmpty { return email }
        if let name = identity.name, !name.isEmpty { return name }
        return identity.title
    }

    public func clearLiveAuth() throws {
        try persistLiveIntoMatchingProfile()
        try SecureFile.removeIfPresent(paths.authFile)
    }

    public func prepareForNewLogin() async throws {
        try persistLiveIntoMatchingProfile()
        try clearLoginArtifacts()
        await clients.stopForSwitch(restartChatGPT: true, restartEditorServer: false)
        try Task.checkCancellation()
        try SecureFile.removeIfPresent(paths.authFile)
    }

    public func restoreAfterLogin(previousProfileID: UUID?) async throws {
        try clearLoginArtifacts()
        if let previousProfileID {
            let target = try store.loadSnapshot(previousProfileID)
            await clients.stopForSwitch(restartChatGPT: true, restartEditorServer: false)
            do {
                try writeLiveFile(target)
            } catch {
                await clients.startAfterSwitch(restartChatGPT: true)
                throw error
            }
            await clients.startAfterSwitch(restartChatGPT: true)
        } else {
            await clients.startAfterSwitch(restartChatGPT: true)
        }
    }

    public func loginDidFinish() -> Bool {
        guard FileManager.default.fileExists(atPath: paths.loginMarker.path) else { return false }
        guard let live = try? readLiveFile(), live.identity != nil else { return false }
        return true
    }

    @discardableResult
    public func completeNewLogin(name: String) async throws -> Profile {
        let profile = try saveNewLogin(name: name)
        let snapshot = try store.loadSnapshot(profile.id)
        try clearLoginArtifacts()
        await clients.stopForSwitch(restartChatGPT: true, restartEditorServer: false)
        do {
            try writeLiveFile(snapshot)
        } catch {
            await clients.startAfterSwitch(restartChatGPT: true)
            throw error
        }
        await clients.startAfterSwitch(restartChatGPT: true)
        return profile
    }

    public func clearLoginArtifacts() throws {
        for url in [paths.loginMarker, paths.loginState, paths.loginProcess, paths.loginTTY] {
            try SecureFile.removeIfPresent(url)
        }
    }

    func saveNewLogin(name: String) throws -> Profile {
        guard let live = try readLiveFile() else { throw SwitcherError.missingAuthFile }
        if let existing = try store.profileMatching(live) {
            return try store.save(name: existing.displayName, snapshot: live, replacing: existing.id)
        }
        return try store.save(name: name, snapshot: live)
    }

    func persistLiveIntoMatchingProfile() throws {
        guard let live = try readLiveFile() else { return }
        if let existing = try store.profileMatching(live) {
            _ = try store.save(name: existing.displayName, snapshot: live, replacing: existing.id)
        }
    }

    func readLiveFile() throws -> AuthSnapshot? {
        guard FileManager.default.fileExists(atPath: paths.authFile.path) else { return nil }
        do {
            return try AuthSnapshot(data: try SecureFile.read(paths.authFile))
        } catch {
            throw SwitcherError.invalidAuthFile
        }
    }

    func writeLiveFile(_ snapshot: AuthSnapshot) throws {
        try SecureFile.atomicWrite(snapshot.data, to: paths.authFile)
    }

    public func writeLiveSnapshot(_ snapshot: AuthSnapshot) throws {
        try writeLiveFile(snapshot)
        try persistLiveIntoMatchingProfile()
    }

    /// Discard a network refresh if another operation has replaced the source login.
    @discardableResult
    public func applyUsageRefresh(_ updated: AuthSnapshot, replacing original: AuthSnapshot, profileID: UUID?) throws -> Bool {
        try Task.checkCancellation()
        if let profileID {
            guard let current = try? store.loadSnapshot(profileID), current.data == original.data else { return false }
            try replaceSnapshot(profileID, with: updated)
        } else {
            guard try readLiveFile()?.data == original.data else { return false }
        }
        if try readLiveFile()?.data == original.data {
            try writeLiveFile(updated)
        }
        return true
    }

    public func replaceSnapshot(_ id: UUID, with snapshot: AuthSnapshot) throws {
        let existing = try store.list().first { $0.id == id }
        guard let existing else { throw SwitcherError.profileNotFound }
        _ = try store.save(name: existing.displayName, snapshot: snapshot, replacing: id)
    }
}
