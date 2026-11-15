import Foundation
import AgentUI
import ClaudeProfilesCore

/// What the status menu shows for Claude.
extension AppState {
    /// Numbers older than this, while Claude runs and could refresh them,
    /// stop posing as live.
    static let staleAfter: TimeInterval = 30 * 60

    var cardModel: UsageCardModel {
        var card = UsageCardModel(provider: .claude)
        switch mode {
        case .needsSetup:
            card.placeholder = "Profiles are not set up yet. Setting up saves your current Claude login as the first profile."
        case .ready:
            guard let active = activeProfile else {
                card.placeholder = "No active profile. Pick one below."
                break
            }
            card.account = active
            card.badge = activeCLIProfile == active ? "Desktop · CLI" : "Desktop"
            if let usage = usage[active] {
                card.subtitle = UsageFormat.updatedText(usage.asOf)
                card.isStale = claude.isRunning && Date().timeIntervalSince(usage.asOf) > Self.staleAfter
                let outdated = card.isStale
                card.limits = ([Self.limit("Session", usage.fiveHour, window: 5 * 3600, outdated: outdated),
                                Self.limit("Weekly", usage.sevenDay, window: 7 * 86400, outdated: outdated)]
                               + usage.scoped.map {
                                   Self.limit("Weekly · \($0.name)", $0.window, window: 7 * 86400, outdated: outdated)
                               })
                    .compactMap { $0 }
                if let extra = usage.extraUsage {
                    let used = UsageFormat.money(extra.used, currency: extra.currency)
                    card.details = [UsageDetail(
                        title: "Extra usage",
                        value: extra.limit.map { "\(used) of \(UsageFormat.money($0, currency: extra.currency))" } ?? used,
                        used: extra.limit.map { min(100, 100 * extra.used / max($0, 0.01)) })]
                }
                if card.isStale {
                    card.notice = "Claude hasn't saved new usage numbers since then, so what's left now is unknown."
                    card.noticeTone = .warning
                }
            } else {
                card.placeholder = "No usage data yet. Claude records it after this profile's first use."
            }
        }
        if !claudeAppFound {
            card.notice = "Claude.app not found in /Applications or ~/Applications."
            card.noticeTone = .warning
        } else if brokenLink {
            card.notice = "The Claude folder link is broken. Switching to any profile repairs it."
            card.noticeTone = .error
        } else if isSwitching {
            card.notice = "Switching profiles…"
            card.noticeTone = .info
        }
        return card
    }

    /// Every profile but the active Desktop one, in the saved order.
    var menuAccounts: [UsageAccount] {
        guard mode == .ready else { return [] }
        return allProfiles.filter { $0 != activeProfile }.map { name in
            let profileUsage = usage[name]
            return UsageAccount(id: name, title: name,
                                session: Self.limit("Session", profileUsage?.fiveHour, window: 5 * 3600),
                                weekly: Self.limit("Weekly", profileUsage?.sevenDay, window: 7 * 86400))
        }
    }

    var canSwitchDesktop: Bool { mode == .ready && !isSwitching && claudeAppFound }

    /// An expired window has reset since Claude last looked: 100% and no countdown.
    /// An `outdated` reading says nothing about now: what's left is unknown. Its
    /// figure and reset time stay only while its window hasn't reset since.
    static func limit(_ title: String, _ usage: ProfileUsage.Window?, window: TimeInterval,
                      outdated: Bool = false) -> UsageLimit? {
        guard let usage else { return nil }
        if outdated {
            return usage.expired
                ? UsageLimit(title: title, remaining: nil, window: window)
                : UsageLimit(title: title, remaining: nil, resetsAt: usage.resetsAt, window: window,
                             lastSeen: Double(usage.remainingPercent))
        }
        return UsageLimit(title: title, remaining: Double(usage.remainingPercent),
                          resetsAt: usage.expired ? nil : usage.resetsAt, window: window)
    }
}
