import Foundation
import PlatformSupport

public enum ProfileError: LocalizedError, Equatable {
    case invalidName
    case profileExists(String)
    case profileNotFound(String)
    case refusedToClobber(String)
    case nothingToMigrate
    case invalidBackup(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Profile name must contain at least one of A–Z, 0–9, _ or -."
        case .profileExists(let name):
            return "Profile “\(name)” already exists."
        case .profileNotFound(let name):
            return "Profile “\(name)” does not exist."
        case .refusedToClobber(let path):
            return "\(path) exists and is not a symlink; refusing to touch it."
        case .nothingToMigrate:
            return "The Claude directory is already managed; migration is not needed."
        case .invalidBackup(let name):
            return "“\(name)” is not a session backup folder (no profile session trees inside)."
        }
    }
}

public enum ClaudeDirState: Equatable {
    case missing
    case realDirectory
    case symlink(target: URL?, valid: Bool)
    case otherFile
}

/// All filesystem logic. No UI, no AppKit — fully testable against a fake home directory.
public final class ProfileManager: Sendable {
    public static let sessionTrees = ["claude-code-sessions", "local-agent-mode-sessions"]

    public let home: URL
    private var fm: FileManager { .default }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    public var claudeDir: URL { PlatformPaths.appData(home: home).appendingPathComponent("Claude") }
    public var profilesDir: URL { PlatformPaths.appData(home: home).appendingPathComponent("Claude-Profiles") }
    public var sharedDir: URL { profilesDir.appendingPathComponent("_shared-sessions") }
    // Display order for the unified list, one name per line. `_` prefix keeps
    // profiles() from listing it. Order is a plain list, never dir renames —
    // renaming a profile would log its CLI side out (path = Keychain identity).
    private var orderFile: URL { profilesDir.appendingPathComponent("_order") }
    private var autoSetupDisabledFile: URL { profilesDir.appendingPathComponent("_auto-setup-disabled") }

    // MARK: - Inspection

    public func claudeDirState() -> ClaudeDirState {
        if isSymlink(claudeDir) {
            let target = try? DirectoryLink.destination(of: claudeDir)
            let valid = target.map { isRealDirectory($0) } ?? false
            return .symlink(target: target, valid: valid)
        }
        switch itemType(claudeDir) {
        case nil: return .missing
        case .typeDirectory?: return .realDirectory
        default: return .otherFile
        }
    }

    public func profiles() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: profilesDir.path)) ?? []
        return names
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") && isRealDirectory(profilesDir.appendingPathComponent($0)) }
            .sorted()
    }

    public func savedOrder() -> [String] {
        guard let raw = try? String(contentsOf: orderFile, encoding: .utf8) else { return [] }
        return raw.split(whereSeparator: \.isNewline).map(String.init)
    }

    public func saveOrder(_ names: [String]) throws {
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try (names.joined(separator: "\n") + "\n").write(to: orderFile, atomically: true, encoding: .utf8)
    }

    /// Sort `names` by the saved order; names not in the file (created outside
    /// the app, or before ordering existed) fall to the end alphabetically — so
    /// a freshly created profile shows up last until the user drags it.
    public func ordered(_ names: [String]) -> [String] {
        let rank = Dictionary(savedOrder().enumerated().map { ($1, $0) },
                              uniquingKeysWith: { first, _ in first })
        return names.sorted {
            switch (rank[$0], rank[$1]) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return $0 < $1
            }
        }
    }

    public func activeProfile() -> String? {
        guard case .symlink(let target?, true) = claudeDirState(),
              target.deletingLastPathComponent().path == profilesDir.path
        else { return nil }
        return target.lastPathComponent
    }

    public var sharedHistoryEnabled: Bool { isRealDirectory(sharedDir) }

    /// Deleting the active or last Desktop profile opts out of adopting a new
    /// standalone Claude login. Explicit setup re-enables it.
    public var automaticSetupAllowed: Bool { !itemExists(autoSetupDisabledFile) }

    public static func sanitize(_ raw: String) -> String? {
        // @ and . allowed so email addresses work as profile names.
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-@."
        let name = String(raw.filter { allowed.contains($0) })
        return name.isEmpty || name.allSatisfy({ $0 == "." }) ? nil : name
    }

    // MARK: - Operations

    /// First-run migration: move the real Claude dir into a profile (or create an
    /// empty profile if the dir is missing) and replace it with a symlink.
    public func migrate(name rawName: String) throws {
        guard let name = Self.sanitize(rawName) else { throw ProfileError.invalidName }
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let dest = profilesDir.appendingPathComponent(name)
        guard !itemExists(dest) else { throw ProfileError.profileExists(name) }

        switch claudeDirState() {
        case .realDirectory:
            try fm.moveItem(at: claudeDir, to: dest)
        case .missing:
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        case .symlink, .otherFile:
            throw ProfileError.nothingToMigrate
        }
        try pointClaudeDir(at: dest)
        if itemExists(autoSetupDisabledFile) { try fm.removeItem(at: autoSetupDisabledFile) }
    }

    public func switchTo(name: String) throws {
        let dest = profilesDir.appendingPathComponent(name)
        guard isRealDirectory(dest) else { throw ProfileError.profileNotFound(name) }
        try pointClaudeDir(at: dest)
    }

    @discardableResult
    public func createProfile(name rawName: String) throws -> String {
        guard let name = Self.sanitize(rawName) else { throw ProfileError.invalidName }
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let dir = profilesDir.appendingPathComponent(name)
        guard !itemExists(dir) else { throw ProfileError.profileExists(name) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if sharedHistoryEnabled {
            for tree in Self.sessionTrees {
                let sharedTree = sharedDir.appendingPathComponent(tree)
                guard isRealDirectory(sharedTree) else { continue }
                try DirectoryLink.create(at: dir.appendingPathComponent(tree), pointingTo: sharedTree)
            }
        }
        return name
    }

    // MARK: - Rename / delete

    /// Rename a profile. If it is the active one, the symlink is repointed —
    /// callers must have Claude quit in that case.
    @discardableResult
    public func renameProfile(_ name: String, to rawNewName: String) throws -> String {
        guard let newName = Self.sanitize(rawNewName) else { throw ProfileError.invalidName }
        guard newName != name else { return name }
        let src = profilesDir.appendingPathComponent(name)
        guard isRealDirectory(src) else { throw ProfileError.profileNotFound(name) }
        let dst = profilesDir.appendingPathComponent(newName)
        guard !itemExists(dst) else { throw ProfileError.profileExists(newName) }
        let wasActive = activeProfile() == name
        try fm.moveItem(at: src, to: dst)
        if wasActive { try pointClaudeDir(at: dst) } // keep the symlink valid
        return newName
    }

    /// Delete a profile — this is "logout": the account's login state is removed.
    /// Callers must have Claude quit before deleting the active profile. Its
    /// link is removed too, so deleting the last profile leaves no broken link.
    public func deleteProfile(name: String) throws {
        let dir = profilesDir.appendingPathComponent(name)
        guard isRealDirectory(dir) else { throw ProfileError.profileNotFound(name) }
        let wasActive = activeProfile() == name
        if wasActive || profiles().count == 1 {
            try Data().write(to: autoSetupDisabledFile, options: .atomic)
        }
        if wasActive { try DirectoryLink.remove(at: claudeDir) }
        do {
            try DirectoryLink.removeTree(at: dir) // shared trees are symlinks inside it — shared history survives
        } catch {
            if wasActive, isRealDirectory(dir) { try? pointClaudeDir(at: dir) }
            throw error
        }
    }

    /// Merge every profile's session trees into `_shared-sessions` and symlink them back.
    /// Returns the backup directory, or nil when there was nothing to migrate (idempotent re-run).
    ///
    /// `promoteActive` makes the live account own the master: its `<account>/<org>`
    /// becomes the real session pile and every other account links to it. Claude
    /// then always reads and writes a real directory, never a symlink its own
    /// writes could shadow with a fresh (empty) one — the cause of sessions
    /// vanishing from the sidebar after a switch. Callers that run at a known-idle
    /// moment (switch, Claude quit, launch) pass true; tests default to false.
    @discardableResult
    public func enableSharedHistory(now: Date = Date(), promoteActive: Bool = false) throws -> URL? {
        let names = profiles()
        let active = promoteActive ? activeProfile() : nil

        // Backup first: copy every real (not yet symlinked) session tree.
        let backup = try backupRealTrees(tag: "backup", now: now)

        // Merge each profile tree into the shared tree, then symlink it back.
        for tree in Self.sessionTrees {
            let sharedTree = sharedDir.appendingPathComponent(tree)
            try fm.createDirectory(at: sharedTree, withIntermediateDirectories: true)
            for profile in names {
                let link = profilesDir.appendingPathComponent(profile).appendingPathComponent(tree)
                if isSymlink(link) { continue }
                if isRealDirectory(link) {
                    try merge(contentsOf: link, into: sharedTree)
                    try DirectoryLink.removeTree(at: link)
                }
                // Missing trees get linked too, so future sessions land in the shared tree.
                try DirectoryLink.create(at: link, pointingTo: sharedTree)
            }
            let preferred = active.flatMap { activeOrgDir(in: sharedTree, profile: $0) }
            let master = try consolidateOrgDirs(in: sharedTree, preferred: preferred)
            try prelinkAccounts(in: sharedTree, master: master, profiles: names)
        }
        return backup
    }

    /// The active account's `<account>/<org>` path inside `tree`, once Claude has
    /// recorded its ids. With several orgs it must be the org Claude will run
    /// under: Claude Desktop 4.23118+ opens its session dir with O_NOFOLLOW and
    /// refuses to save into a symlink (ENOTDIR), so a master in the wrong org
    /// silently drops every new session. Without evidence of the live org, prefer
    /// one that already holds real sessions, else any that exists, else the first —
    /// whichever we pick becomes the real master and the rest link to it, so every
    /// org of the account still resolves to the pile.
    private func activeOrgDir(in tree: URL, profile name: String) -> URL? {
        let dir = profilesDir.appendingPathComponent(name)
        guard let account = accountID(of: dir) else { return nil }
        let orgs = orgIDs(of: dir).sorted()
        guard !orgs.isEmpty else { return nil }
        let accountDir = tree.appendingPathComponent(account)
        if let live = lastUsedOrg(of: dir, account: account, among: orgs) {
            return accountDir.appendingPathComponent(live)
        }
        let candidates = orgs.map { accountDir.appendingPathComponent($0) }
        return candidates.first(where: isRealDirectory)
            ?? candidates.first(where: itemExists)
            ?? candidates.first
    }

    /// The org Claude last ran this account under, newest evidence wins: the
    /// `dxt:allowlistLastUpdated:<org>` stamp in config.json and the mtime of
    /// `plugin-list/<account>/<org>` — Claude refreshes both only for the org it
    /// is signed in to. Nil when neither exists for any org.
    func lastUsedOrg(of profileDir: URL, account: String, among orgs: [String]) -> String? {
        let config = configJSON(of: profileDir) ?? [:]
        let pluginList = profileDir.appendingPathComponent("plugin-list").appendingPathComponent(account)
        var best: (org: String, at: Date)?
        for org in orgs {
            var stamps: [Date] = []
            if let raw = config["dxt:allowlistLastUpdated:\(org)"] as? String, let at = Self.parseISODate(raw) {
                stamps.append(at)
            }
            let listed = pluginList.appendingPathComponent(org)
            if let at = (try? fm.attributesOfItem(atPath: listed.path))?[.modificationDate] as? Date {
                stamps.append(at)
            }
            guard let at = stamps.max() else { continue }
            if best == nil || at > best!.at { best = (org, at) } // orgs are sorted: ties keep the first
        }
        return best?.org
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let at = fmt.date(from: raw) { return at }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: raw)
    }

    public enum LiveOrgState: Equatable {
        /// Sharing off, nothing active, or no telling which org Claude runs under.
        case unknown
        /// The live org dir is the real master in every shared tree — all good.
        case master
        /// The live org dir is a symlink: Claude cannot save sessions until a
        /// promoting relink (Claude quit) makes it the real master.
        case linked
        /// Missing, or a real island beside the master: Claude saves fine but
        /// shows only part of the combined list until the next relink.
        case detached
    }

    /// Where the org Claude is (most likely) running under stands in the shared
    /// trees. Read-only and cheap, so safe to poll while Claude runs.
    public func liveOrgState() -> LiveOrgState {
        guard sharedHistoryEnabled, let name = activeProfile() else { return .unknown }
        let dir = profilesDir.appendingPathComponent(name)
        guard let account = accountID(of: dir) else { return .unknown }
        let orgs = orgIDs(of: dir).sorted()
        guard let org = lastUsedOrg(of: dir, account: account, among: orgs) ?? (orgs.count == 1 ? orgs[0] : nil)
        else { return .unknown }
        var state = LiveOrgState.master
        for tree in Self.sessionTrees {
            let sharedTree = sharedDir.appendingPathComponent(tree)
            let live = sharedTree.appendingPathComponent(account).appendingPathComponent(org)
            if isSymlink(live) { return .linked }
            let realOrgs = ((try? realSubdirectories(of: sharedTree)) ?? [])
                .flatMap { (try? realSubdirectories(of: $0)) ?? [] }
            if realOrgs.isEmpty { continue } // nothing shared in this tree yet
            if !isRealDirectory(live) || realOrgs.count > 1 { state = .detached }
        }
        return state
    }

    /// Undo sharing. Merged sessions cannot be split back per account, so the
    /// honest semantics are: every profile keeps its own real copy of the
    /// combined history (for the account/org ids Claude recorded at login),
    /// and sessions created afterwards stay per-profile. Only touches links —
    /// a profile whose tree is still a real directory is left alone.
    public func disableSharedHistory() throws {
        guard sharedHistoryEnabled else { return }
        let names = profiles()
        for tree in Self.sessionTrees {
            let sharedTree = sharedDir.appendingPathComponent(tree)
            for profile in names {
                let profileDir = profilesDir.appendingPathComponent(profile)
                let link = profileDir.appendingPathComponent(tree)
                guard isSymlink(link) else { continue }
                try DirectoryLink.remove(at: link)
                try fm.createDirectory(at: link, withIntermediateDirectories: true)
                guard isRealDirectory(sharedTree), let account = accountID(of: profileDir) else { continue }
                for org in orgIDs(of: profileDir) {
                    let src = DirectoryLink.resolvingLinks(
                        sharedTree.appendingPathComponent(account).appendingPathComponent(org))
                    let dst = link.appendingPathComponent(account).appendingPathComponent(org)
                    guard isRealDirectory(src), !itemExists(dst) else { continue }
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: src, to: dst)
                }
            }
        }
        try DirectoryLink.removeTree(at: sharedDir)
    }

    /// Copy every real (not-yet-symlinked) session tree to
    /// `~/claude-session-<tag>-<timestamp>/<profile>/<tree>`. Nil when nothing is real
    /// (everything already symlinked into the shared tree, or no sessions yet).
    @discardableResult
    private func backupRealTrees(tag: String, now: Date) throws -> URL? {
        var realTrees: [(profile: String, tree: String)] = []
        for profile in profiles() {
            for tree in Self.sessionTrees
            where isRealDirectory(profilesDir.appendingPathComponent(profile).appendingPathComponent(tree)) {
                realTrees.append((profile, tree))
            }
        }
        guard !realTrees.isEmpty else { return nil }
        let backupDir = home.appendingPathComponent("claude-session-\(tag)-\(timestamp(now))")
        for (profile, tree) in realTrees {
            let src = profilesDir.appendingPathComponent(profile).appendingPathComponent(tree)
            let dst = backupDir.appendingPathComponent(profile).appendingPathComponent(tree)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        }
        return backupDir
    }

    private func timestamp(_ now: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: now)
    }

    public struct RestoreResult {
        /// The current trees, saved before restoring so the restore is itself reversible.
        public let prerestoreBackup: URL?
        /// The `_shared-sessions` pile, moved aside. Post-enable sessions live here as one
        /// undifferentiated set — they cannot be split back per account.
        public let sharedArchive: URL?
        /// Profiles renamed since the backup, matched to their old folder by
        /// account: current name → name in the backup.
        public var renamed: [String: String] = [:]
    }

    /// True per-account rollback: reset every existing profile to its own sessions from
    /// `backupDir` (a `claude-session-backup-*` written when sharing was enabled). Pre-enable
    /// history comes back exactly; the shared pile is archived — not deleted, and not
    /// re-attributed, because sessions made while sharing was on have no per-account origin.
    /// Needs Claude down, like enable/disable.
    @discardableResult
    public func restoreFromBackup(_ backupDir: URL, now: Date = Date()) throws -> RestoreResult {
        // Reject a stray folder: it must hold at least one <profile>/<sessionTree>.
        guard isRealDirectory(backupDir),
              try realSubdirectories(of: backupDir).contains(where: { prof in
                  Self.sessionTrees.contains { isRealDirectory(prof.appendingPathComponent($0)) }
              })
        else { throw ProfileError.invalidBackup(backupDir.lastPathComponent) }

        // Save the current state first so this restore can itself be undone.
        let prerestore = try backupRealTrees(tag: "prerestore", now: now)

        // Which backup folder is whose: read before anything is reset.
        let sources = try backupSources(in: backupDir)

        // Reset each existing profile to the backup's copy — or an empty tree when the
        // backup predates it (a profile created after sharing was enabled).
        for name in profiles() {
            for tree in Self.sessionTrees {
                let target = profilesDir.appendingPathComponent(name).appendingPathComponent(tree)
                if itemExists(target) { try DirectoryLink.removeTree(at: target) } // symlink or real dir
                let src = sources[name].map { backupDir.appendingPathComponent($0).appendingPathComponent(tree) }
                if let src, isRealDirectory(src) {
                    try fm.copyItem(at: src, to: target)
                } else {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
            }
        }

        // Archive the combined pile instead of deleting it; this also flips
        // sharedHistoryEnabled back to false (the shared dir no longer exists).
        var archive: URL?
        if isRealDirectory(sharedDir) {
            let dst = home.appendingPathComponent("claude-shared-archive-\(timestamp(now))")
            try fm.moveItem(at: sharedDir, to: dst)
            archive = dst
        }
        // ponytail: not transactional across profiles; the prerestore backup is the recovery path.
        var result = RestoreResult(prerestoreBackup: prerestore, sharedArchive: archive)
        result.renamed = sources.filter { $0.key != $0.value }
        return result
    }

    /// Current profile → its folder in `backupDir`. Backups are keyed by the
    /// profile's name at backup time, so a profile renamed since then has no
    /// folder of its own name (#11). Its sessions are filed under its Claude
    /// account id, which a rename doesn't change, so that finds the folder:
    /// 1. the same-named folder, unless it clearly holds a different account
    ///    (the name was reused after a rename);
    /// 2. otherwise the one unclaimed folder holding the profile's account;
    /// 3. otherwise, when exactly one profile and one folder named after no
    ///    current profile are left, each other. Sessions are filed under
    ///    their account, so even a wrong pairing never shows one account's
    ///    history to another; the prerestore backup undoes it.
    func backupSources(in backupDir: URL) throws -> [String: String] {
        var folders: [String: Set<String>] = [:] // backup folder → accounts filed in it
        for folder in try realSubdirectories(of: backupDir) {
            let trees = Self.sessionTrees.map { folder.appendingPathComponent($0) }.filter(isRealDirectory)
            guard !trees.isEmpty else { continue }
            folders[folder.lastPathComponent] = Set(try trees.flatMap { try realSubdirectories(of: $0) }.map(\.lastPathComponent))
        }
        let names = profiles()
        let accounts = Dictionary(uniqueKeysWithValues: names.map { ($0, knownAccounts(of: $0)) })
        var sources: [String: String] = [:]
        var claimed: Set<String> = []
        for name in names {
            guard let held = folders[name] else { continue }
            let mine = accounts[name] ?? []
            if mine.isEmpty || held.isEmpty || !mine.isDisjoint(with: held) {
                sources[name] = name
                claimed.insert(name)
            }
        }
        for name in names where sources[name] == nil {
            let mine = accounts[name] ?? []
            guard !mine.isEmpty else { continue }
            let matches = folders.filter { !claimed.contains($0.key) && !mine.isDisjoint(with: $0.value) }
            guard matches.count == 1, let folder = matches.first?.key else { continue }
            sources[name] = folder
            claimed.insert(folder)
        }
        let leftProfiles = names.filter { sources[$0] == nil && folders[$0] == nil }
        let leftFolders = folders.keys.filter { !claimed.contains($0) && !names.contains($0) }
        if leftProfiles.count == 1, leftFolders.count == 1 {
            sources[leftProfiles[0]] = leftFolders[0]
        }
        return sources
    }

    /// Claude account ids this profile's sessions are filed under: the one it
    /// recorded at login, else the account folders of its own (unshared) trees.
    private func knownAccounts(of name: String) -> Set<String> {
        let dir = profilesDir.appendingPathComponent(name)
        if let account = accountID(of: dir) { return [account] }
        var found: Set<String> = []
        for tree in Self.sessionTrees {
            let path = dir.appendingPathComponent(tree)
            guard isRealDirectory(path) else { continue } // a shared link holds everyone's
            found.formUnion(((try? realSubdirectories(of: path)) ?? []).map(\.lastPathComponent))
        }
        return found
    }

    /// Safe while Claude is running: only creates missing symlinks — never merges,
    /// moves, or deletes. Lets an inactive account that logged in earlier join the
    /// combined list without waiting for a full quit-time merge.
    /// The active profile is skipped: Claude may be about to create its own org dir,
    /// and a symlink there would make every save fail (Claude 4.23118+ refuses a
    /// symlinked session dir). Its dir joins the pile at the next promoting relink.
    /// Returns how many links were created.
    @discardableResult
    public func prelinkKnownAccounts() throws -> Int {
        guard sharedHistoryEnabled else { return 0 }
        let active = activeProfile()
        let names = profiles().filter { $0 != active }
        var created = 0
        for tree in Self.sessionTrees {
            let sharedTree = sharedDir.appendingPathComponent(tree)
            var orgDirs: [URL] = []
            for account in try realSubdirectories(of: sharedTree) {
                orgDirs.append(contentsOf: try realSubdirectories(of: account))
            }
            // Steady state has exactly one real org dir (the master). More than one
            // means a merge is pending — leave that to the next quit-time relink.
            guard orgDirs.count == 1 else { continue }
            created += try prelinkAccounts(in: sharedTree, master: orgDirs[0], profiles: names)
        }
        return created
    }

    /// Accounts that logged in but never opened a Code/agent session have no
    /// <account>/<org> dir at all, so their sidebar stays empty even after a merge.
    /// Claude records both uuids in the profile right after login — use them to
    /// symlink the account's org dir to the master ahead of time.
    @discardableResult
    private func prelinkAccounts(in tree: URL, master: URL?, profiles names: [String]) throws -> Int {
        guard let master else { return 0 }
        var created = 0
        for profile in names {
            let profileDir = profilesDir.appendingPathComponent(profile)
            guard let account = accountID(of: profileDir) else { continue }
            for org in orgIDs(of: profileDir) {
                let orgDir = tree.appendingPathComponent(account).appendingPathComponent(org)
                guard !itemExists(orgDir) else { continue } // real or already linked
                try fm.createDirectory(at: orgDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                try DirectoryLink.create(at: orgDir, pointingTo: master)
                created += 1
            }
        }
        return created
    }

    /// True once Claude has written the profile's account/org ids — i.e. the
    /// account has completed its first login. Before that, prelinking is
    /// impossible (the ids are unknowable), which is why a brand-new profile's
    /// sidebar starts empty even with shared history on.
    public func hasAccountIDs(profile name: String) -> Bool {
        let dir = profilesDir.appendingPathComponent(name)
        return accountID(of: dir) != nil && !orgIDs(of: dir).isEmpty
    }

    /// Last usage-limit numbers Claude Desktop saw for this profile's account,
    /// read from the profile's own HTTP cache. Nil when nothing is cached.
    public func usage(profile name: String) -> ProfileUsage? {
        let dir = profilesDir.appendingPathComponent(name)
        return UsageReader.usage(inProfileDir: dir, orgIDs: orgIDs(of: dir))
    }

    /// ownerAccountId from cowork-enabled-cli-ops.json — written on login.
    private func accountID(of profileDir: URL) -> String? {
        guard let data = try? Data(contentsOf: profileDir.appendingPathComponent("cowork-enabled-cli-ops.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["ownerAccountId"] as? String
    }

    private func configJSON(of profileDir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: profileDir.appendingPathComponent("config.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Org uuids from config.json `dxt:<name>:<org-uuid>` keys — written on login.
    private func orgIDs(of profileDir: URL) -> Set<String> {
        guard let json = configJSON(of: profileDir) else { return [] }
        var ids: Set<String> = []
        for key in json.keys where key.hasPrefix("dxt:") {
            let parts = key.split(separator: ":")
            if parts.count == 3, parts[2].count == 36 { ids.insert(String(parts[2])) }
        }
        return ids
    }

    // MARK: - Internals

    /// Repoint the `Claude` symlink. Never deletes anything that is not a symlink.
    /// Atomic (see DirectoryLink.replace): a crash mid-switch can never leave
    /// the path missing or dangling.
    private func pointClaudeDir(at dest: URL) throws {
        switch claudeDirState() {
        case .realDirectory, .otherFile:
            throw ProfileError.refusedToClobber(claudeDir.path)
        case .missing, .symlink:
            try DirectoryLink.replace(at: claudeDir, pointingTo: dest)
        }
    }

    /// Recursive copy that never overwrites an existing file.
    private func merge(contentsOf src: URL, into dst: URL) throws {
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            let s = src.appendingPathComponent(name)
            let d = dst.appendingPathComponent(name)
            if !itemExists(d) {
                try fm.copyItem(at: s, to: d)
            } else if isRealDirectory(s), isRealDirectory(d) {
                try merge(contentsOf: s, into: d)
            }
            // else: destination exists — never overwrite.
        }
    }

    /// Collapse a shared tree to a single real `<account>/<org>` master with every
    /// other org dir symlinked to it. The master is `preferred` (the active
    /// account's org dir) when given — relocated there so the live Claude owns a
    /// real pile — otherwise the real dir with the most files. Returns the master.
    ///
    /// The final pass points every other org entry straight at the master: real
    /// islands (a fresh dir Claude wrote before it was linked) are merged in, and
    /// stale/looping symlinks are re-pointed — so a moved master never leaves a
    /// broken link or a growing symlink chain behind.
    @discardableResult
    private func consolidateOrgDirs(in tree: URL, preferred: URL? = nil) throws -> URL? {
        // Every <account>/<org> entry, real dirs and symlinks alike.
        func orgEntries() throws -> [URL] {
            var out: [URL] = []
            for account in try realSubdirectories(of: tree) {
                for name in (try? fm.contentsOfDirectory(atPath: account.path)) ?? [] {
                    let u = account.appendingPathComponent(name)
                    if isRealDirectory(u) || isSymlink(u) { out.append(u) }
                }
            }
            return out
        }

        let realOrgs = try orgEntries().filter(isRealDirectory).sorted { $0.path < $1.path }
        guard !realOrgs.isEmpty else { return nil }

        // The pile: real dir with the most files (deterministic tie-break by path).
        var pile = realOrgs[0]
        var bestCount = fileCount(in: pile)
        for dir in realOrgs.dropFirst() {
            let count = fileCount(in: dir)
            if count > bestCount { pile = dir; bestCount = count }
        }

        // Master follows the active account: relocate the pile into its org dir,
        // leaving a symlink where the pile used to be so old accounts still resolve.
        // Fold any island already at `preferred` into the pile first, then move the
        // pile wholesale — so none of the pile's files can be lost to a name clash.
        var master = pile
        if let preferred, preferred.path != pile.path {
            if isRealDirectory(preferred) { try merge(contentsOf: preferred, into: pile) }
            if itemExists(preferred) { try DirectoryLink.removeTree(at: preferred) } // island dir or stale symlink
            try fm.createDirectory(at: preferred.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: pile, to: preferred)
            try DirectoryLink.create(at: pile, pointingTo: preferred)
            master = preferred
        }

        // ponytail: rewrites all links every relink (O(accounts)); fine at this scale.
        for entry in try orgEntries() where entry.path != master.path {
            if isRealDirectory(entry) {
                try merge(contentsOf: entry, into: master)
                try DirectoryLink.removeTree(at: entry)
            } else if (try? DirectoryLink.destination(of: entry))?.path == master.path {
                continue // already points straight at the master
            } else {
                try DirectoryLink.remove(at: entry)
            }
            try DirectoryLink.create(at: entry, pointingTo: master)
        }
        return master
    }

    private func realSubdirectories(of url: URL) throws -> [URL] {
        guard isRealDirectory(url) else { return [] }
        return try fm.contentsOfDirectory(atPath: url.path)
            .map { url.appendingPathComponent($0) }
            .filter { isRealDirectory($0) }
    }

    private func fileCount(in dir: URL) -> Int {
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let file as URL in enumerator
        where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            count += 1
        }
        return count
    }

    // lstat semantics: attributesOfItem does not traverse the final symlink,
    // so these are safe on broken symlinks and never confuse a link with a dir.
    // The link checks cover Windows junctions, which can read as directories
    // (or not at all, once dangling).
    private func itemType(_ url: URL) -> FileAttributeType? {
        (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    private func itemExists(_ url: URL) -> Bool { itemType(url) != nil || isSymlink(url) }
    private func isSymlink(_ url: URL) -> Bool { DirectoryLink.isLink(url) }
    private func isRealDirectory(_ url: URL) -> Bool { itemType(url) == .typeDirectory && !isSymlink(url) }
}
