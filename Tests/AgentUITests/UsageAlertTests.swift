import Foundation
import Testing
@testable import AgentUI

@Suite struct UsageAlertTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let settings = UsageAlertSettings(useItOrLoseIt: true)

    func session(_ remaining: Double, resetsIn: TimeInterval = 3600) -> UsageLimit {
        UsageLimit(title: "Session", remaining: remaining, resetsAt: now.addingTimeInterval(resetsIn), window: 5 * 3600)
    }

    func plan(_ limits: [UsageLimit], previous: [String: Double] = [:], fired: Set<String> = []) -> [UsageAlert] {
        UsageAlertPlanner.alerts(provider: "Claude", account: "work", limits: limits, settings: settings,
                                 now: now, previous: previous, fired: fired)
    }

    @Test func onlyTheDeepestThresholdFires() {
        #expect(plan([session(80, resetsIn: 3.5 * 3600)]).isEmpty)
        #expect(plan([session(22, resetsIn: 600)]).map(\.kind) == [.warning])
        #expect(plan([session(8, resetsIn: 600)]).map(\.kind) == [.critical])
        #expect(plan([session(0)]).map(\.kind) == [.depleted])
    }

    @Test func firesOncePerWindow() {
        let first = plan([session(8, resetsIn: 600)])
        #expect(plan([session(7, resetsIn: 590)], fired: Set(first.map(\.key))).isEmpty)
        // A later window has its own key.
        #expect(plan([session(7, resetsIn: 5 * 3600)], fired: Set(first.map(\.key))).count == 1)
    }

    @Test func paceWarnsBeforeTheCriticalLevel() {
        // 1h into a 5h window with 50% used: runs out at 2h, three hours early.
        let alerts = plan([session(50, resetsIn: 4 * 3600)])
        #expect(alerts.map(\.kind) == [.willRunOut])
    }

    @Test func restoredAfterReset() {
        let key = UsageAlertPlanner.limitKey(provider: "Claude", account: "work", limit: "Session")
        let alerts = plan([session(100, resetsIn: 5 * 3600)], previous: [key: 3])
        #expect(alerts.map(\.kind) == [.restored])
    }

    @Test func weeklyUnusedBeforeReset() {
        let weekly = UsageLimit(title: "Weekly", remaining: 70, resetsAt: now.addingTimeInterval(10 * 3600), window: 7 * 86400)
        #expect(plan([weekly]).map(\.kind) == [.useItOrLoseIt])
        var off = settings
        off.useItOrLoseIt = false
        #expect(UsageAlertPlanner.alerts(provider: "Claude", account: "work", limits: [weekly], settings: off,
                                         now: now, previous: [:], fired: []).isEmpty)
    }
}

@Suite struct UsageFormatTests {
    @Test func masksEmailsOnlyWhenAsked() {
        #expect(UsageFormat.personal("jane@example.com", hide: true) == "j•••@example.com")
        #expect(UsageFormat.personal("jane@example.com", hide: false) == "jane@example.com")
        #expect(UsageFormat.personal("work", hide: true) == "work")
    }

    @Test func sharesReadLeftOrUsed() {
        #expect(UsageFormat.share(58, showsUsed: false) == "58% left")
        #expect(UsageFormat.share(58, showsUsed: true) == "42% used")
        #expect(UsageFormat.compact(nil, showsUsed: true) == "–")
    }

    @Test func leaderOnlyWhenOneAccountLeads() {
        func account(_ id: String, _ session: Double, _ weekly: Double) -> UsageAccount {
            UsageAccount(id: id, title: id, session: UsageLimit(title: "Session", remaining: session),
                         weekly: UsageLimit(title: "Weekly", remaining: weekly))
        }
        #expect(UsageAccount.leader(in: [account("a", 100, 100), account("b", 100, 100), account("c", 100, 100)]) == nil)
        #expect(UsageAccount.leader(in: [account("a", 88, 65), account("b", 100, 100), account("c", 9, 36)])?.id == "b")
        #expect(UsageAccount.leader(in: [account("a", 30, 90), account("b", 20, 100)]) == nil, "not well clear")
        #expect(UsageAccount.leader(in: [account("a", 100, 100)]) == nil, "a lone account needs no mark")
    }

    @Test func accountUsableIsTheTighterWindow() {
        let account = UsageAccount(id: "a", title: "a", session: UsageLimit(title: "Session", remaining: 80),
                                   weekly: UsageLimit(title: "Weekly", remaining: 30))
        #expect(account.usable == 30)
        #expect(UsageAccount(id: "b", title: "b", session: nil, weekly: UsageLimit(title: "Weekly", remaining: 40)).usable == 40)
    }
}
