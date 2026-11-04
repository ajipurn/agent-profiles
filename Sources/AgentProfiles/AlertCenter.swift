import Foundation
import AgentUI

/// Sends the usage notifications UsageAlertPlanner says are due, for every
/// provider, and remembers what fired so each one goes out once per window
/// (across relaunches too). A critical or used-up Claude or Codex limit
/// suggests the account with the most left; clicking switches to it.
@MainActor
final class AlertCenter {
    private static let firedKey = "alertsFired"
    /// Fired keys and when they may be forgotten (a week covers any window).
    private var fired: [String: Date]
    private var previous: [String: Double] = [:]

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.firedKey) as? [String: Double] ?? [:]
        let now = Date()
        fired = stored.mapValues(Date.init(timeIntervalSince1970:)).filter { $0.value > now }
    }

    /// `switchKey` is the notification userInfo key the app delegate reads
    /// to switch accounts ("switchTo" for Claude, "switchCodex" for Codex).
    func evaluate(provider: String, account: String?, limits: [UsageLimit],
                  alternatives: [UsageAccount] = [], switchKey: String? = nil) {
        guard let account, !limits.isEmpty else { return }
        let settings = UsageAlertSettings.current
        let due = UsageAlertPlanner.alerts(provider: provider, account: account, limits: limits, settings: settings,
                                           previous: previous, fired: Set(fired.keys))
        for limit in limits {
            previous[UsageAlertPlanner.limitKey(provider: provider, account: account, limit: limit.title)] = limit.remaining
        }
        guard !due.isEmpty else { return }
        let expiry = Date().addingTimeInterval(8 * 86_400)
        for alert in due {
            fired[alert.key] = expiry
            var body = alert.body
            var userInfo: [String: String] = [:]
            if let switchKey, [.critical, .depleted, .willRunOut].contains(alert.kind),
               let best = Self.best(alternatives, for: alert.limitTitle) {
                body += (body.isEmpty ? "" : " ") + "Click to switch to \(best.title) (\(UsageFormat.percent(best.usable)) left)."
                userInfo[switchKey] = best.id
            }
            Notifier.post(alert.title, body, userInfo: userInfo)
        }
        UserDefaults.standard.set(fired.mapValues(\.timeIntervalSince1970), forKey: Self.firedKey)
    }

    private var expiredSignIns: Set<String> = []

    /// Once per lapse: the provider's saved sign-in was refused.
    func signIn(provider: String, expired: Bool) {
        if expired, expiredSignIns.insert(provider).inserted {
            Notifier.post("\(provider): sign in again", "Its saved sign-in no longer works, so usage can't be updated.")
        } else if !expired {
            expiredSignIns.remove(provider)
        }
    }

    /// The other account with the most left, if it is well clear.
    static func best(_ accounts: [UsageAccount], for limit: String) -> UsageAccount? {
        accounts.filter { ($0.usable ?? 0) > 40 }.max { ($0.usable ?? 0) < ($1.usable ?? 0) }
    }
}
