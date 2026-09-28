import Foundation
import AgentUI
import CodexProfilesCore

/// What the status menu shows for Codex.
extension AppModel {
    public var cardModel: UsageCardModel {
        var card = UsageCardModel(provider: .codex)
        if live?.file == nil {
            card.placeholder = profiles.isEmpty
                ? "Not signed in. Add an account to get started."
                : "Not signed in. Pick an account below."
        } else {
            card.account = currentTitle
            card.badge = (liveUsage.usage?.planType ?? live?.identity?.plan).map(AccountIdentity.displayPlan)
            if live?.file?.isChatGPTSession == false {
                card.placeholder = "API key session: billed per token, no quota windows."
            } else if let usage = liveUsage.usage {
                card.subtitle = UsageFormat.updatedText(usage.fetchedAt)
                card.limits = usage.windows.map(Self.limit)
                if let credits = usage.creditsBalance {
                    card.notice = "Credits: \(credits)"
                }
            } else {
                card.placeholder = liveUsage.isLoading ? "Loading usage…" : "No usage data yet."
            }
            if let failure = liveUsage.error {
                card.notice = failure
                card.noticeTone = .warning
                card.isStale = true
            } else if needsSave {
                card.notice = "This account is not saved yet. Save it in Settings."
                card.noticeTone = .warning
            }
        }
        // The panel's own status line has no other place to show up now.
        if let error {
            card.notice = error
            card.noticeTone = .error
        } else if let status {
            card.notice = status
            card.noticeTone = .info
        }
        return card
    }

    /// Saved accounts other than the active one, in the Settings sort order.
    public var menuAccounts: [UsageAccount] {
        ProfileList.arranged(
            profiles, query: "", favoritesOnly: false, settings: settings,
            activeID: live?.matchingProfileID, usage: profileUsage
        )
        .filter { $0.id != live?.matchingProfileID }
        .map { profile in
            UsageAccount(
                id: profile.id.uuidString,
                title: displayName(for: profile),
                remaining: profileUsage[profile.id]?.usage.flatMap(Self.sessionRemaining),
                isFavorite: settings.favoriteProfileIDs.contains(profile.id))
        }
    }

    public var canSwitch: Bool { !isBusy && !pendingNewLogin }

    /// True while Settings has something to ask (a name for a new or unsaved account).
    public var isEditing: Bool { editor != nil }

    /// Saved accounts in hotkey order (⌃⌥1…9): favorites first, then by
    /// name. Unlike the menu, this ignores the active account and usage, so
    /// a number keeps pointing at the same account.
    public var hotkeyAccountIDs: [String] {
        var byName = settings
        byName.sortOrder = .name
        return ProfileList.arranged(profiles, query: "", favoritesOnly: false, settings: byName,
                                    activeID: nil, usage: [:])
            .map(\.id.uuidString)
    }

    /// A saved account whose name, label or email is `name` (any case).
    public func accountID(matching name: String) -> String? {
        profiles.first { profile in
            [profile.name, profile.displayName, profile.identity?.email ?? ""]
                .contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }?.id.uuidString
    }

    public func accountName(_ accountID: String) -> String? {
        profiles.first { $0.id.uuidString == accountID }.map(displayName(for:))
    }

    public var activeAccountID: String? { live?.matchingProfileID?.uuidString }

    public var restartsChatGPT: Bool { settings.restartChatGPT }

    public var lastError: String? { error }

    public func switchTo(accountID: String) {
        guard let profile = profiles.first(where: { $0.id.uuidString == accountID }) else { return }
        switchTo(profile)
    }

    static func limit(_ window: UsageWindow) -> UsageLimit {
        let title = switch window.label {
        case "5h": "Session"
        case "Wk": "Weekly"
        default: "\(window.label) limit"
        }
        return UsageLimit(title: title, remaining: window.remainingPercent, resetsAt: window.resetAt)
    }

    static func sessionRemaining(_ usage: CodexUsage) -> Double? {
        (usage.windows.first { $0.label == "5h" } ?? usage.windows.first)?.remainingPercent
    }
}
