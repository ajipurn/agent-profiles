import Foundation
import CodexProfilesCore

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure.failed(message) }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "") throws {
    if lhs != rhs {
        throw TestFailure.failed("\(message) expected \(rhs), got \(lhs)")
    }
}

enum AuthFixtures {
    static func jwt(
        email: String,
        name: String,
        accountID: String,
        plan: String,
        organizations: [String] = [],
        workspaceID: String? = nil
    ) -> String {
        let header = base64URL(["alg": "none", "typ": "JWT"])
        let orgs: [[String: Any]] = organizations.enumerated().map { index, title in
            [
                "id": "org-\(index)",
                "is_default": index == 0,
                "role": "owner",
                "title": title,
            ]
        }
        let payload = base64URL([
            "email": email,
            "name": name,
            "sub": "auth0|\(accountID)",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": workspaceID ?? accountID,
                "chatgpt_user_id": accountID,
                "user_id": accountID,
                "chatgpt_plan_type": plan,
                "organizations": orgs,
            ],
        ])
        return "\(header).\(payload).sig"
    }

    static func authJSON(
        email: String,
        name: String,
        accountID: String,
        plan: String,
        organizations: [String] = ["Acme"],
        authMode: String = "chatgpt",
        workspaceID: String? = nil
    ) -> Data {
        let token = jwt(
            email: email,
            name: name,
            accountID: accountID,
            plan: plan,
            organizations: organizations,
            workspaceID: workspaceID
        )
        let root: [String: Any] = [
            "auth_mode": authMode,
            "OPENAI_API_KEY": NSNull(),
            "last_refresh": "2026-01-01T00:00:00Z",
            "tokens": [
                "id_token": token,
                "access_token": "access-\(accountID)",
                "refresh_token": "refresh-\(accountID)",
                "account_id": workspaceID ?? accountID,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func snapshot(
        email: String,
        name: String = "User",
        accountID: String,
        plan: String = "team",
        organizations: [String] = ["Acme"],
        workspaceID: String? = nil
    ) throws -> AuthSnapshot {
        try AuthSnapshot(
            data: authJSON(
                email: email,
                name: name,
                accountID: accountID,
                plan: plan,
                organizations: organizations,
                workspaceID: workspaceID
            )
        )
    }

    static func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@main
enum CodexProfilesCheck {
    static func main() async {
        var failed = 0
        let cases: [(String, () async throws -> Void)] = [
            ("accepts signed HTTPS update configuration", validUpdateConfiguration),
            ("rejects incomplete or insecure update configuration", invalidUpdateConfiguration),
            ("migrates legacy settings without losing preferences", migrateSettings),
            ("round trips favorites and display preferences", settingsRoundTrip),
            ("filters accounts by multiple terms and favorites", filterProfiles),
            ("sorts active and favorite accounts ahead of quota order", sortProfiles),
            ("applies token refresh to the matching live and saved account", guardedRefresh),
            ("does not overwrite an account switched during refresh", staleRefreshAfterSwitch),
            ("does not replace newer credentials or resurrect deleted profiles", staleRefreshCredentials),
            ("rejects cancelled token refresh writes", cancelledRefresh),
            ("uses the fetch timestamp for relative quota resets", relativeUsageReset),
            ("handles quota boundaries and invalid percentages", usageBoundaries),
            ("parses ChatGPT account from auth JSON", parseIdentity),
            ("treats API key auth as identity", parseAPIKey),
            ("saves profiles without putting tokens in meta", saveWithoutTokens),
            ("rejects duplicate names", rejectDuplicateNames),
            ("updates existing profile for the same account", updateSameAccount),
            ("keeps the original name when the same account is saved again", keepNameOnSameAccount),
            ("replaces a stale email label when identity email changes", repairStaleEmailLabel),
            ("does not match profiles when identity is missing", skipNilIdentityMatch),
            ("switch replaces the live auth file", switchAccounts),
            ("persists refreshed live tokens before switching away", persistBeforeSwitch),
            ("add login keeps the previous profile and restarts Codex", addLoginKeepsPreviousProfile),
            ("cancelled login restores the previous profile and clears artifacts", restoreAfterCancelledLogin),
            ("add login of the same account does not rename the saved profile", addLoginSameAccountKeepsName),
            ("keeps two ChatGPT users in the same workspace as separate profiles", sameWorkspaceDifferentUsers),
            ("prefers ChatGPT user id over workspace account id", parseUserNotWorkspace),
            ("reads workspace account id from auth tokens", parseWorkspaceAccountID),
            ("parses Codex 5h and weekly usage windows", parseUsageWindows),
            ("prefers ChatGPT remaining_percent over used_percent", parseRemainingPercent),
            ("formats quota reset like ChatGPT", formatResetCaption),
            ("keeps a custom nickname when refreshing tokens", applyTokenRefreshPreservesIdentity),
        ]
        for (name, test) in cases {
            do {
                try await test()
                print("ok  \(name)")
            } catch {
                failed += 1
                print("FAIL  \(name): \(error)")
            }
        }
        if failed > 0 {
            print("\(failed) failed")
            exit(1)
        }
        print("\(cases.count) passed")
    }

    static func validUpdateConfiguration() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let config = UpdateConfiguration(feedURL: "https://github.com/owner/app/releases/latest/download/appcast.xml", publicKey: key)
        try expectEqual(config?.publicKey, key)
        try expectEqual(config?.feedURL.scheme, "https")
    }

    static func invalidUpdateConfiguration() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        for url: String? in [nil, "", "http://example.com/feed", "file:///tmp/feed", "https://user:password@example.com/feed"] {
            try expect(UpdateConfiguration(feedURL: url, publicKey: key) == nil, "unsafe update URL accepted")
        }
        for badKey: String? in [nil, "", "placeholder", Data(repeating: 1, count: 31).base64EncodedString()] {
            try expect(UpdateConfiguration(feedURL: "https://example.com/feed", publicKey: badKey) == nil, "invalid signing key accepted")
        }
    }

    static func migrateSettings() throws {
        let legacy = Data(#"{"restartChatGPT":false,"restartEditorServer":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
        try expectEqual(settings.restartChatGPT, false)
        try expectEqual(settings.restartEditorServer, true)
        try expectEqual(settings.favoriteProfileIDs, [])
        try expectEqual(settings.sortOrder, .name)
        try expect(settings.autoRefresh, "auto refresh default missing")
        let future = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sortOrder":"future"}"#.utf8))
        try expectEqual(future.sortOrder, .name)
    }

    static func settingsRoundTrip() throws {
        try withStore { store in
            var settings = AppSettings(restartChatGPT: false)
            settings.favoriteProfileIDs = [UUID(), UUID()]
            settings.hideEmails = true
            settings.autoRefresh = false
            settings.showMenuBarUsage = true
            settings.sortOrder = .mostAvailable
            try store.saveSettings(settings)
            try expectEqual(store.loadSettings(), settings)
        }
    }

    static func filterProfiles() throws {
        let work = Profile(name: "Design", identity: AccountIdentity(accountID: "a", email: "ada@example.com", organizations: ["Café Studio"]))
        let personal = Profile(name: "Personal")
        var settings = AppSettings()
        settings.favoriteProfileIDs = [work.id]
        let result = ProfileList.arranged([personal, work], query: "  ADA cafe ", favoritesOnly: false,
                                         settings: settings, activeID: nil, usage: [:])
        try expectEqual(result.map(\.id), [work.id])
        let favorites = ProfileList.arranged([personal, work], query: "", favoritesOnly: true,
                                            settings: settings, activeID: nil, usage: [:])
        try expectEqual(favorites.map(\.id), [work.id])
        let noMatch = ProfileList.arranged([work], query: "other", favoritesOnly: false,
                                          settings: settings, activeID: nil, usage: [:])
        try expect(noMatch.isEmpty, "search should have no results")
    }

    static func sortProfiles() throws {
        let active = Profile(name: "Z active")
        let favorite = Profile(name: "Y favorite")
        let low = Profile(name: "A low")
        let high = Profile(name: "B high")
        let unknown = Profile(name: "C unknown")
        var settings = AppSettings()
        settings.sortOrder = .mostAvailable
        settings.favoriteProfileIDs = [favorite.id]
        let usage: [UUID: UsageLoadState] = [
            low.id: UsageLoadState(usage: CodexUsage(primary: UsageWindow(usedPercent: 90))),
            high.id: UsageLoadState(usage: CodexUsage(primary: UsageWindow(usedPercent: 10))),
        ]
        let result = ProfileList.arranged([low, unknown, high, favorite, active], query: "", favoritesOnly: false,
                                         settings: settings, activeID: active.id, usage: usage)
        try expectEqual(result.map(\.id), [active.id, favorite.id, high.id, low.id, unknown.id])
        settings.sortOrder = .recentlyAdded
        let old = Profile(name: "A", createdAt: Date(timeIntervalSince1970: 0))
        let new = Profile(name: "Z", createdAt: Date(timeIntervalSince1970: 10))
        let recent = ProfileList.arranged([old, new], query: "", favoritesOnly: false,
                                         settings: settings, activeID: nil, usage: [:])
        try expectEqual(recent.map(\.id), [new.id, old.id])
    }

    static func guardedRefresh() throws {
        let original = try AuthFixtures.snapshot(email: "a@example.com", accountID: "a")
        let updated = try original.applyingTokenRefresh(accessToken: "updated", refreshToken: nil, idToken: nil)
        try withSwitcher(live: original) { env in
            let profile = try env.switcher.saveCurrent(name: "Work")
            let applied = try env.switcher.applyUsageRefresh(updated, replacing: original, profileID: profile.id)
            try expect(applied, "valid refresh was discarded")
            try expectEqual(try env.switcher.liveState().file, updated)
            try expectEqual(try env.switcher.store.loadSnapshot(profile.id), updated)
            try expectEqual(try env.switcher.profiles().first?.name, "Work")
        }
    }

    static func staleRefreshAfterSwitch() async throws {
        let original = try AuthFixtures.snapshot(email: "a@example.com", accountID: "a")
        let other = try AuthFixtures.snapshot(email: "b@example.com", accountID: "b")
        let updated = try original.applyingTokenRefresh(accessToken: "updated", refreshToken: nil, idToken: nil)
        try await withSwitcher(live: original) { env in
            let first = try env.switcher.saveCurrent(name: "First")
            let second = try env.switcher.store.save(name: "Second", snapshot: other)
            try await env.switcher.switchTo(second.id)
            try expect(try env.switcher.applyUsageRefresh(updated, replacing: original, profileID: first.id), "saved account should refresh")
            try expectEqual(try env.switcher.liveState().file, other, "late refresh switched the live account")
            try expectEqual(try env.switcher.store.loadSnapshot(first.id), updated)
            try expectEqual(try env.switcher.applyUsageRefresh(updated, replacing: original, profileID: nil), false)
        }
    }

    static func staleRefreshCredentials() throws {
        let original = try AuthFixtures.snapshot(email: "a@example.com", accountID: "a")
        let newer = try original.applyingTokenRefresh(accessToken: "newer", refreshToken: nil, idToken: nil)
        try withSwitcher(live: original) { env in
            let profile = try env.switcher.saveCurrent(name: "Work")
            try env.switcher.writeLiveSnapshot(newer)
            try expectEqual(try env.switcher.applyUsageRefresh(original, replacing: original, profileID: profile.id), false)
            try expectEqual(try env.switcher.liveState().file, newer)
            try env.switcher.delete(profile.id)
            try expectEqual(try env.switcher.applyUsageRefresh(newer, replacing: original, profileID: profile.id), false)
            try expect(try env.switcher.profiles().isEmpty, "deleted profile was recreated")
        }
    }

    static func cancelledRefresh() async throws {
        let original = try AuthFixtures.snapshot(email: "a@example.com", accountID: "a")
        try await withSwitcher(live: original) { env in
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    try env.switcher.applyUsageRefresh(original, replacing: original, profileID: nil)
                    throw TestFailure.failed("cancelled write was allowed")
                } catch is CancellationError { }
            }
            try await task.value
            try expectEqual(try env.switcher.liveState().file, original)
        }
    }

    static func relativeUsageReset() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let usage = CodexUsage.parse(root: ["rate_limit": ["primary_window": [
            "used_percent": 25, "reset_after_seconds": 60,
        ]]], fetchedAt: fetchedAt)
        try expectEqual(usage.primary?.resetAt, fetchedAt.addingTimeInterval(60))
    }

    static func usageBoundaries() throws {
        try expectEqual(UsageWindow(usedPercent: -20).remainingDisplay, 100)
        try expectEqual(UsageWindow(usedPercent: 120).remainingDisplay, 0)
        try expectEqual(UsageWindow(usedPercent: .nan).remainingDisplay, 0)
        try expectEqual(CodexUsage(allowed: false).severity, .exhausted)
        let usage = CodexUsage.parse(root: ["rate_limit": ["primary_window": ["used_percent": Double.infinity]]])
        try expect(usage.windows.isEmpty, "nonfinite server value should not become a quota")
        let partial = CodexUsage(limitReached: true, primary: UsageWindow(usedPercent: 100), secondary: UsageWindow(usedPercent: 20))
        try expectEqual(partial.secondary?.remainingDisplay, 80, "one exhausted window must not erase another window")
    }

    static func parseIdentity() throws {
        let data = AuthFixtures.authJSON(
            email: "work@example.com",
            name: "Ada Lovelace",
            accountID: "acc-work",
            plan: "team",
            organizations: ["FrontMind", "Personal"]
        )
        let identity = try AccountIdentityParser.parse(authJSON: data)
        try expectEqual(identity?.email, "work@example.com")
        try expectEqual(identity?.name, "Ada Lovelace")
        try expectEqual(identity?.accountID, "acc-work")
        try expectEqual(identity?.plan, "team")
        try expectEqual(identity?.organizations, ["FrontMind", "Personal"])
        try expectEqual(identity?.title, "work@example.com")
        try expectEqual(identity?.subtitle, "Team · FrontMind")
    }

    static func parseAPIKey() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "apikey",
            "OPENAI_API_KEY": "sk-test",
        ])
        let identity = try AccountIdentityParser.parse(authJSON: data)
        try expectEqual(identity?.accountID, "api-key")
        try expectEqual(identity?.title, "API key")
    }

    static func saveWithoutTokens() throws {
        try withStore { store in
            let snapshot = try AuthFixtures.snapshot(email: "a@example.com", accountID: "acc-a")
            let saved = try store.save(name: " Work ", snapshot: snapshot)
            try expectEqual(saved.name, "Work")
            let listed = try store.list()
            try expectEqual(listed.map(\.name), ["Work"])
            try expectEqual(listed.first?.identity?.email, "a@example.com")
            let meta = try Data(contentsOf: store.paths.profileMeta(saved.id))
            let raw = String(data: meta, encoding: .utf8) ?? ""
            try expect(!raw.contains("access-acc-a"), "meta leaked access token")
            try expect(!raw.contains("refresh-acc-a"), "meta leaked refresh token")
        }
    }

    static func rejectDuplicateNames() throws {
        try withStore { store in
            _ = try store.save(name: "Work", snapshot: try AuthFixtures.snapshot(email: "a@example.com", accountID: "acc-a"))
            do {
                _ = try store.save(
                    name: "work",
                    snapshot: try AuthFixtures.snapshot(email: "b@example.com", accountID: "acc-b")
                )
                throw TestFailure.failed("expected duplicate name to throw")
            } catch SwitcherError.profileNameTaken {
                return
            }
        }
    }

    static func updateSameAccount() throws {
        try withStore { store in
            let first = try store.save(name: "Work", snapshot: try AuthFixtures.snapshot(email: "a@example.com", accountID: "acc-a"))
            let second = try store.save(
                name: "Work",
                snapshot: try AuthFixtures.snapshot(email: "a@example.com", name: "Ada", accountID: "acc-a")
            )
            try expectEqual(first.id, second.id)
            try expectEqual(try store.list().count, 1)
            try expectEqual(second.identity?.name, "Ada")
        }
    }

    static func keepNameOnSameAccount() throws {
        try withStore { store in
            _ = try store.save(name: "Work", snapshot: try AuthFixtures.snapshot(email: "a@example.com", accountID: "acc-a"))
            let second = try store.save(
                name: "Personal",
                snapshot: try AuthFixtures.snapshot(email: "a@example.com", accountID: "acc-a")
            )
            try expectEqual(second.name, "Work")
            try expectEqual(try store.list().map(\.name), ["Work"])
        }
    }

    static func repairStaleEmailLabel() throws {
        try withStore { store in
            let first = try store.save(
                name: "old@example.com",
                snapshot: try AuthFixtures.snapshot(email: "old@example.com", accountID: "acc-a")
            )
            let second = try store.save(
                name: "ignored",
                snapshot: try AuthFixtures.snapshot(email: "new@example.com", accountID: "acc-a")
            )
            try expectEqual(first.id, second.id)
            try expectEqual(second.name, "new@example.com")
            try expectEqual(try store.list().map(\.name), ["new@example.com"])
            try expectEqual(second.displayName, "new@example.com")
        }
    }

    static func skipNilIdentityMatch() throws {
        try withStore { store in
            let opaque = try AuthSnapshot(data: try JSONSerialization.data(withJSONObject: [
                "auth_mode": "chatgpt",
                "tokens": [:] as [String: Any],
            ]))
            _ = try store.save(name: "Work", snapshot: try AuthFixtures.snapshot(email: "a@example.com", accountID: "acc-a"))
            try expect(try store.profileMatching(opaque) == nil, "nil identity should not match a saved account")
            let extra = try store.save(name: "Other", snapshot: opaque)
            try expectEqual(extra.name, "Other")
            try expectEqual(try store.list().count, 2)
        }
    }

    static func switchAccounts() async throws {
        try await withSwitcher(
            live: try AuthFixtures.snapshot(email: "work@example.com", accountID: "acc-work")
        ) { env in
            _ = try env.switcher.saveCurrent(name: "Work")
            let home = try AuthFixtures.snapshot(email: "home@example.com", accountID: "acc-home")
            try SecureFile.atomicWrite(home.data, to: env.paths.authFile)
            _ = try env.switcher.saveCurrent(name: "Home")
            let workProfile = try env.switcher.profiles().first { $0.name == "Work" }!
            try await env.switcher.switchTo(workProfile.id)
            let live = try AccountIdentityParser.parse(authJSON: try Data(contentsOf: env.paths.authFile))
            try expectEqual(live?.email, "work@example.com")
            try expectEqual(env.clients.stopCount, 1)
            try expectEqual(env.clients.startCount, 1)
        }
    }

    static func persistBeforeSwitch() async throws {
        let work = try AuthFixtures.snapshot(email: "work@example.com", name: "Old", accountID: "acc-work")
        try await withSwitcher(live: work) { env in
            let saved = try env.switcher.saveCurrent(name: "Work")
            let home = try AuthFixtures.snapshot(email: "home@example.com", accountID: "acc-home")
            try SecureFile.atomicWrite(home.data, to: env.paths.authFile)
            _ = try env.switcher.saveCurrent(name: "Home")
            let refreshed = try AuthFixtures.snapshot(email: "work@example.com", name: "New", accountID: "acc-work")
            try SecureFile.atomicWrite(refreshed.data, to: env.paths.authFile)
            let homeProfile = try env.switcher.profiles().first { $0.name == "Home" }!
            try await env.switcher.switchTo(homeProfile.id)
            let storedWork = try env.switcher.store.loadSnapshot(saved.id)
            try expectEqual(storedWork.identity?.name, "New")
        }
    }

    static func addLoginKeepsPreviousProfile() async throws {
        try await withSwitcher(
            live: try AuthFixtures.snapshot(email: "work@example.com", accountID: "acc-work")
        ) { env in
            _ = try env.switcher.saveCurrent(name: "Work")
            try await env.switcher.prepareForNewLogin()
            try expectEqual(env.clients.stopCount, 1)
            try expect(!FileManager.default.fileExists(atPath: env.paths.authFile.path), "live auth should be cleared")
            try expectEqual(try env.switcher.profiles().map(\.name), ["Work"])
            let home = try AuthFixtures.snapshot(email: "home@example.com", accountID: "acc-home")
            try SecureFile.atomicWrite(home.data, to: env.paths.authFile)
            try "done".write(to: env.paths.loginMarker, atomically: true, encoding: .utf8)
            for artifact in [env.paths.loginState, env.paths.loginProcess, env.paths.loginTTY] {
                try SecureFile.atomicWrite(Data("temporary".utf8), to: artifact)
            }
            try expect(env.switcher.loginDidFinish(), "login marker plus identity should finish")
            let saved = try await env.switcher.completeNewLogin(name: "Home")
            try expectEqual(saved.name, "Home")
            try expectEqual(try env.switcher.profiles().map(\.name), ["Home", "Work"])
            try expectEqual(env.clients.stopCount, 2)
            try expectEqual(env.clients.startCount, 1)
            for artifact in [env.paths.loginMarker, env.paths.loginState, env.paths.loginProcess, env.paths.loginTTY] {
                try expect(
                    !FileManager.default.fileExists(atPath: artifact.path),
                    "login artifact should be cleared: \(artifact.lastPathComponent)"
                )
            }
        }
    }

    static func addLoginSameAccountKeepsName() async throws {
        try await withSwitcher(
            live: try AuthFixtures.snapshot(email: "work@example.com", accountID: "acc-work")
        ) { env in
            let work = try env.switcher.saveCurrent(name: "Work")
            let refreshed = try AuthFixtures.snapshot(email: "work@example.com", name: "Ada", accountID: "acc-work")
            try SecureFile.atomicWrite(refreshed.data, to: env.paths.authFile)
            let saved = try await env.switcher.completeNewLogin(name: "Personal")
            try expectEqual(saved.id, work.id)
            try expectEqual(saved.name, "Work")
            try expectEqual(try env.switcher.profiles().count, 1)
        }
    }

    static func restoreAfterCancelledLogin() async throws {
        try await withSwitcher(
            live: try AuthFixtures.snapshot(email: "work@example.com", accountID: "acc-work")
        ) { env in
            let work = try env.switcher.saveCurrent(name: "Work")
            try await env.switcher.prepareForNewLogin()
            let interrupted = try AuthFixtures.snapshot(email: "home@example.com", accountID: "acc-home")
            try SecureFile.atomicWrite(interrupted.data, to: env.paths.authFile)
            for artifact in [env.paths.loginMarker, env.paths.loginState, env.paths.loginProcess, env.paths.loginTTY] {
                try SecureFile.atomicWrite(Data("temporary".utf8), to: artifact)
            }

            try await env.switcher.restoreAfterLogin(previousProfileID: work.id)

            let restored = try env.switcher.liveState()
            try expectEqual(restored.identity?.email, "work@example.com")
            try expectEqual(restored.matchingProfileID, work.id)
            try expectEqual(env.clients.stopCount, 2)
            try expectEqual(env.clients.startCount, 1)
            for artifact in [env.paths.loginMarker, env.paths.loginState, env.paths.loginProcess, env.paths.loginTTY] {
                try expect(
                    !FileManager.default.fileExists(atPath: artifact.path),
                    "login artifact should be cleared: \(artifact.lastPathComponent)"
                )
            }
        }
    }

    static func sameWorkspaceDifferentUsers() throws {
        try withStore { store in
            let first = try store.save(
                name: "Work",
                snapshot: try AuthFixtures.snapshot(
                    email: "work@example.com",
                    accountID: "user-work",
                    workspaceID: "team-workspace"
                )
            )
            let second = try store.save(
                name: "Home",
                snapshot: try AuthFixtures.snapshot(
                    email: "home@example.com",
                    accountID: "user-home",
                    workspaceID: "team-workspace"
                )
            )
            try expect(first.id != second.id, "shared workspace must not merge different users")
            try expectEqual(try store.list().map(\.name), ["Home", "Work"])
            let liveHome = try AuthFixtures.snapshot(
                email: "home@example.com",
                accountID: "user-home",
                workspaceID: "team-workspace"
            )
            try expectEqual(try store.profileMatching(liveHome)?.id, second.id)
        }
    }

    static func parseUserNotWorkspace() throws {
        let data = AuthFixtures.authJSON(
            email: "work@example.com",
            name: "Ada",
            accountID: "user-work",
            plan: "team",
            workspaceID: "team-workspace"
        )
        let identity = try AccountIdentityParser.parse(authJSON: data)
        try expectEqual(identity?.accountID, "user-work")
        try expectEqual(identity?.email, "work@example.com")
    }

    static func parseWorkspaceAccountID() throws {
        let snapshot = try AuthFixtures.snapshot(
            email: "work@example.com",
            accountID: "user-work",
            workspaceID: "team-workspace"
        )
        try expectEqual(snapshot.workspaceAccountID, "team-workspace")
        try expectEqual(snapshot.accountID, "user-work")
        try expect(snapshot.isChatGPTSession, "fixture should look like a ChatGPT session")
        try expect(!snapshot.accessTokenNeedsRefresh, "opaque fixture tokens should not force a refresh")
    }

    static func parseUsageWindows() throws {
        let json: [String: Any] = [
            "plan_type": "team",
            "rate_limit": [
                "allowed": true,
                "limit_reached": false,
                "primary_window": [
                    "used_percent": 15,
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_800_000_000,
                ],
                "secondary_window": [
                    "used_percent": 69.4,
                    "limit_window_seconds": 604_800,
                    "reset_after_seconds": 3600,
                ],
            ],
            "rate_limit_reset_credits": [
                "available_count": 1,
            ],
            "credits": [
                "balance": "12.5",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let usage = try CodexUsage.parse(json: data)
        try expectEqual(usage.planType, "team")
        try expectEqual(usage.primary?.remainingDisplay, 85)
        try expectEqual(usage.primary?.label, "5h")
        try expectEqual(usage.secondary?.remainingDisplay, 31)
        try expectEqual(usage.secondary?.label, "Wk")
        try expectEqual(usage.resetCredits, 1)
        try expectEqual(usage.creditsBalance, "12.5")
        try expectEqual(usage.severity, .healthy)
        try expectEqual(UsageWindow.label(forWindowSeconds: 18_000), "5h")
        try expectEqual(UsageWindow.compactDuration(2 * 3600 + 15 * 60), "2h 15m")
        let exhausted = CodexUsage(
            limitReached: true,
            primary: UsageWindow(usedPercent: 100, windowSeconds: 18_000)
        )
        try expectEqual(exhausted.severity, .exhausted)
        try expectEqual(exhausted.compactLine, "Limit reached")
    }

    static func parseRemainingPercent() throws {
        let usage = CodexUsage.parse(root: [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 85,
                    "remaining_percent": 17,
                    "limit_window_seconds": 18_000,
                ],
                "secondary_window": [
                    "remaining_percent": "87.4",
                    "limit_window_seconds": 604_800,
                ],
            ],
        ])
        try expectEqual(usage.primary?.remainingDisplay, 17, "ChatGPT remaining_percent should win over used_percent")
        try expectEqual(usage.secondary?.remainingDisplay, 87)
        try expectEqual(usage.secondary?.label, "Wk")
    }

    static func formatResetCaption() throws {
        let soon = Date().addingTimeInterval(3_600)
        let soonCaption = UsageWindow(usedPercent: 83, resetAt: soon, windowSeconds: 18_000).resetCaption
        try expect(soonCaption != nil, "today’s reset should show a clock time")
        try expect(soonCaption?.contains(":") == true, "today’s reset should look like 3:11 PM, got \(soonCaption ?? "nil")")

        let later = Date().addingTimeInterval(6 * 86_400)
        let laterCaption = UsageWindow(usedPercent: 13, resetAt: later, windowSeconds: 604_800).resetCaption
        try expect(laterCaption != nil, "weekly reset should show a date")
        try expect(laterCaption?.contains(":") != true, "weekly reset should look like Sep 12, got \(laterCaption ?? "nil")")
    }

    static func applyTokenRefreshPreservesIdentity() throws {
        let snapshot = try AuthFixtures.snapshot(email: "work@example.com", accountID: "user-work")
        let updated = try snapshot.applyingTokenRefresh(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: nil
        )
        try expectEqual(updated.identity?.email, "work@example.com")
        try expectEqual(updated.accessToken, "new-access")
        try expectEqual(updated.refreshToken, "new-refresh")
        let raw = String(data: updated.data, encoding: .utf8) ?? ""
        try expect(raw.contains("new-access"), "refreshed access token missing")
        try expect(raw.contains("last_refresh"), "last_refresh should be updated")
    }

    static func withStore(_ body: (ProfileStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(
            paths: CodexPaths(
                codexHome: root.appendingPathComponent("codex"),
                storeRoot: root.appendingPathComponent("store")
            )
        )
        try body(store)
    }

    struct Env {
        var paths: CodexPaths
        var clients: NullCodexClients
        var switcher: AccountSwitcher
    }

    static func withSwitcher(
        live: AuthSnapshot,
        _ body: (Env) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexPaths(
            codexHome: root.appendingPathComponent("codex"),
            storeRoot: root.appendingPathComponent("store")
        )
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        try SecureFile.atomicWrite(live.data, to: paths.authFile)
        let clients = NullCodexClients()
        let switcher = AccountSwitcher(paths: paths, clients: clients)
        try await body(Env(paths: paths, clients: clients, switcher: switcher))
    }

    static func withSwitcher(
        live: AuthSnapshot,
        _ body: (Env) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexPaths(
            codexHome: root.appendingPathComponent("codex"),
            storeRoot: root.appendingPathComponent("store")
        )
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        try SecureFile.atomicWrite(live.data, to: paths.authFile)
        let clients = NullCodexClients()
        let switcher = AccountSwitcher(paths: paths, clients: clients)
        try body(Env(paths: paths, clients: clients, switcher: switcher))
    }
}
