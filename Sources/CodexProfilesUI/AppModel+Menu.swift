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
                    + usage.additional.map { Self.limit($0.window, title: $0.name) }
                card.details = Self.details(usage)
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
            let usage = profileUsage[profile.id]?.usage
            return UsageAccount(
                id: profile.id.uuidString,
                title: displayName(for: profile),
                session: usage?.primary.map(Self.limit),
                weekly: usage?.secondary.map(Self.limit),
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
        profiles.first { $0.matches(name) }?.id.uuidString
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
        case "Limit": "Limit"
        default: "\(window.label) limit"
        }
        return limit(window, title: title)
    }

    static func limit(_ window: UsageWindow, title: String) -> UsageLimit {
        UsageLimit(title: title, remaining: window.remainingPercent, resetsAt: window.resetAt,
                   window: window.windowSeconds.map(TimeInterval.init))
    }

    /// Credits (sold at 4¢ each), a workspace credit cap, and limit resets
    /// waiting to be used.
    static func details(_ usage: CodexUsage) -> [UsageDetail] {
        var lines: [UsageDetail] = []
        if let raw = usage.creditsBalance, let credits = Double(raw) {
            let count = Int(credits.rounded(.down))
            lines.append(UsageDetail(title: "Credits",
                                     value: "\(count.formatted()) · ≈\(UsageFormat.money(Double(count) * 0.04))"))
        } else if let raw = usage.creditsBalance {
            lines.append(UsageDetail(title: "Credits", value: raw))
        }
        if let cap = usage.creditLimit {
            lines.append(UsageDetail(title: "Credit limit",
                                     value: "\(Int(cap.used).formatted()) of \(Int(cap.limit).formatted())",
                                     used: min(100, 100 * cap.used / cap.limit)))
        }
        if let resets = usage.resetCredits, resets > 0 {
            lines.append(UsageDetail(title: "Limit resets", value: "\(resets) available"))
        }
        return lines
    }
}
