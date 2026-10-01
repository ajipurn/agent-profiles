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
                card.limits = [Self.limit("Session", usage.fiveHour, window: 5 * 3600),
                               Self.limit("Weekly", usage.sevenDay, window: 7 * 86400)]
                    .compactMap { $0 }
                card.isStale = claude.isRunning && Date().timeIntervalSince(usage.asOf) > Self.staleAfter
                if card.isStale {
                    card.notice = "Claude has not refreshed these numbers for a while."
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
            UsageAccount(id: name, title: name, remaining: usage[name]?.fiveHourRemaining.map(Double.init))
        }
    }

    var canSwitchDesktop: Bool { mode == .ready && !isSwitching && claudeAppFound }

    /// An expired window has reset since Claude last looked: 100% and no countdown.
    private static func limit(_ title: String, _ usage: ProfileUsage.Window?, window: TimeInterval) -> UsageLimit? {
        guard let usage else { return nil }
        return UsageLimit(title: title, remaining: Double(usage.remainingPercent),
                          resetsAt: usage.expired ? nil : usage.resetsAt, window: window)
    }
}
