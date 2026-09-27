import Foundation

public struct Profile: Equatable, Sendable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var identity: AccountIdentity?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        identity: AccountIdentity? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.identity = identity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String {
        Self.resolvedName(stored: name, identity: identity)
    }

    public static func resolvedName(stored: String, identity: AccountIdentity?) -> String {
        guard let email = identity?.email, looksLikeEmail(stored), looksLikeEmail(email),
              stored.caseInsensitiveCompare(email) != .orderedSame
        else {
            return stored
        }
        return email
    }

    public static func looksLikeEmail(_ value: String) -> Bool {
        guard let at = value.firstIndex(of: "@") else { return false }
        let local = value[..<at]
        let domain = value[value.index(after: at)...]
        return !local.isEmpty && domain.contains(".") && !value.contains(where: \.isWhitespace)
    }
}

public enum ProfileSortOrder: String, Codable, CaseIterable, Sendable {
    case name, mostAvailable, recentlyAdded

    public var title: String {
        switch self {
        case .name: "Name"
        case .mostAvailable: "Most quota available"
        case .recentlyAdded: "Recently added"
        }
    }
}

public struct AppSettings: Equatable, Sendable, Codable {
    public var restartChatGPT: Bool
    public var restartEditorServer: Bool
    public var favoriteProfileIDs: Set<UUID>
    public var sortOrder: ProfileSortOrder
    public var autoRefresh: Bool
    public var showMenuBarUsage: Bool
    public var hideEmails: Bool

    public init(restartChatGPT: Bool = true, restartEditorServer: Bool = false) {
        self.restartChatGPT = restartChatGPT
        self.restartEditorServer = restartEditorServer
        favoriteProfileIDs = []
        sortOrder = .name
        autoRefresh = true
        showMenuBarUsage = false
        hideEmails = false
    }

    private enum CodingKeys: String, CodingKey {
        case restartChatGPT, restartEditorServer, favoriteProfileIDs, sortOrder
        case autoRefresh, showMenuBarUsage, hideEmails
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        restartChatGPT = try values.decodeIfPresent(Bool.self, forKey: .restartChatGPT) ?? true
        restartEditorServer = try values.decodeIfPresent(Bool.self, forKey: .restartEditorServer) ?? false
        favoriteProfileIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .favoriteProfileIDs) ?? []
        let rawSort = try values.decodeIfPresent(String.self, forKey: .sortOrder)
        sortOrder = rawSort.flatMap(ProfileSortOrder.init(rawValue:)) ?? .name
        autoRefresh = try values.decodeIfPresent(Bool.self, forKey: .autoRefresh) ?? true
        showMenuBarUsage = try values.decodeIfPresent(Bool.self, forKey: .showMenuBarUsage) ?? false
        hideEmails = try values.decodeIfPresent(Bool.self, forKey: .hideEmails) ?? false
    }
}

public enum ProfileList {
    public static func arranged(
        _ profiles: [Profile], query: String, favoritesOnly: Bool,
        settings: AppSettings, activeID: UUID?, usage: [UUID: UsageLoadState]
    ) -> [Profile] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return profiles.filter { profile in
            if favoritesOnly && !settings.favoriteProfileIDs.contains(profile.id) { return false }
            let fields = [profile.displayName, profile.identity?.email ?? "", profile.identity?.subtitle ?? ""]
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }.sorted { lhs, rhs in
            if (lhs.id == activeID) != (rhs.id == activeID) { return lhs.id == activeID }
            let leftFavorite = settings.favoriteProfileIDs.contains(lhs.id)
            let rightFavorite = settings.favoriteProfileIDs.contains(rhs.id)
            if leftFavorite != rightFavorite { return leftFavorite }
            switch settings.sortOrder {
            case .name: break
            case .mostAvailable:
                let left = availableQuota(usage[lhs.id])
                let right = availableQuota(usage[rhs.id])
                if left != right { return left > right }
            case .recentlyAdded:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            }
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }
    }

    private static func availableQuota(_ state: UsageLoadState?) -> Double {
        guard let state, state.error == nil, let usage = state.usage else { return -1 }
        if usage.limitReached == true || usage.allowed == false { return 0 }
        return usage.windows.map(\.remainingPercent).min() ?? -1
    }
}

public struct CodexPaths: Equatable, Sendable {
    public var codexHome: URL
    public var storeRoot: URL

    public init(codexHome: URL, storeRoot: URL) {
        self.codexHome = codexHome
        self.storeRoot = storeRoot
    }

    public var authFile: URL {
        codexHome.appendingPathComponent("auth.json")
    }

    public var profilesRoot: URL {
        storeRoot.appendingPathComponent("profiles", isDirectory: true)
    }

    public var settingsFile: URL {
        storeRoot.appendingPathComponent("settings.json")
    }

    public var loginScript: URL {
        storeRoot.appendingPathComponent("login-once.command")
    }

    public var loginMarker: URL {
        storeRoot.appendingPathComponent("login.done")
    }

    public var loginState: URL {
        storeRoot.appendingPathComponent("login.state")
    }

    public var loginProcess: URL {
        storeRoot.appendingPathComponent("login.pid")
    }

    public var loginTTY: URL {
        storeRoot.appendingPathComponent("login.tty")
    }

    public func profileDirectory(_ id: UUID) -> URL {
        profilesRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func profileAuth(_ id: UUID) -> URL {
        profileDirectory(id).appendingPathComponent("auth.json")
    }

    public func profileMeta(_ id: UUID) -> URL {
        profileDirectory(id).appendingPathComponent("meta.json")
    }

    public static func `default`(fileManager: FileManager = .default) -> CodexPaths {
        let home = fileManager.homeDirectoryForCurrentUser
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        return CodexPaths(
            codexHome: home.appendingPathComponent(".codex", isDirectory: true),
            storeRoot: support.appendingPathComponent("CodexProfiles", isDirectory: true)
        )
    }
}

public struct ProfileStore: Sendable {
    public var paths: CodexPaths

    public init(paths: CodexPaths) {
        self.paths = paths
    }

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let settings = try? JSONDecoder.iso8601.decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return settings
    }

    public func saveSettings(_ settings: AppSettings) throws {
        let data = try JSONEncoder.iso8601.encode(settings)
        try SecureFile.atomicWrite(data, to: paths.settingsFile)
    }

    public func list() throws -> [Profile] {
        try SecureFile.ensureDirectory(paths.profilesRoot)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: paths.profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var profiles: [Profile] = []
        for url in urls {
            let metaURL = url.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  var profile = try? JSONDecoder.iso8601.decode(Profile.self, from: data)
            else { continue }
            if let authData = try? Data(contentsOf: paths.profileAuth(profile.id)),
               let snapshot = try? AuthSnapshot(data: authData)
            {
                profile.identity = snapshot.identity
            }
            profiles.append(profile)
        }
        profiles = try persistRepairedEmailLabels(profiles)
        return profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func persistRepairedEmailLabels(_ profiles: [Profile]) throws -> [Profile] {
        var result = profiles
        for index in result.indices {
            let resolved = Profile.resolvedName(stored: result[index].name, identity: result[index].identity)
            guard resolved.caseInsensitiveCompare(result[index].name) != .orderedSame else { continue }
            if result.contains(where: {
                $0.id != result[index].id && $0.name.caseInsensitiveCompare(resolved) == .orderedSame
            }) {
                continue
            }
            result[index].name = resolved
            result[index].updatedAt = Date()
            let meta = try JSONEncoder.iso8601.encode(result[index])
            try SecureFile.atomicWrite(meta, to: paths.profileMeta(result[index].id))
        }
        return result
    }

    public func loadSnapshot(_ id: UUID) throws -> AuthSnapshot {
        let url = paths.profileAuth(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SwitcherError.profileNotFound
        }
        do {
            return try AuthSnapshot(data: try SecureFile.read(url))
        } catch is SwitcherError {
            throw SwitcherError.profileNotFound
        } catch {
            throw SwitcherError.invalidAuthFile
        }
    }

    public func save(name: String, snapshot: AuthSnapshot, replacing id: UUID? = nil) throws -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SwitcherError.profileNameEmpty }

        let existing = try list()
        let now = Date()
        let profile: Profile
        if let id, let found = existing.first(where: { $0.id == id }) {
            if existing.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame && $0.id != id }) {
                throw SwitcherError.profileNameTaken
            }
            profile = Profile(
                id: found.id,
                name: trimmed,
                identity: snapshot.identity,
                createdAt: found.createdAt,
                updatedAt: now
            )
        } else if let identity = snapshot.identity,
                  let matched = existing.first(where: { stored in
                      stored.identity.map { $0.isSameAccount(as: identity) } ?? false
                  }) {
            profile = Profile(
                id: matched.id,
                name: Profile.resolvedName(stored: matched.name, identity: snapshot.identity),
                identity: snapshot.identity,
                createdAt: matched.createdAt,
                updatedAt: now
            )
        } else if existing.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw SwitcherError.profileNameTaken
        } else {
            profile = Profile(name: trimmed, identity: snapshot.identity, createdAt: now, updatedAt: now)
        }

        try SecureFile.ensureDirectory(paths.profileDirectory(profile.id))
        try SecureFile.atomicWrite(snapshot.data, to: paths.profileAuth(profile.id))
        let meta = try JSONEncoder.iso8601.encode(profile)
        try SecureFile.atomicWrite(meta, to: paths.profileMeta(profile.id))
        return profile
    }

    public func rename(_ id: UUID, to name: String) throws -> Profile {
        let snapshot = try loadSnapshot(id)
        return try save(name: name, snapshot: snapshot, replacing: id)
    }

    public func delete(_ id: UUID) throws {
        try SecureFile.removeIfPresent(paths.profileDirectory(id))
    }

    public func profileMatching(_ snapshot: AuthSnapshot) throws -> Profile? {
        guard let identity = snapshot.identity else { return nil }
        return try list().first { stored in
            stored.identity.map { $0.isSameAccount(as: identity) } ?? false
        }
    }
}

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
