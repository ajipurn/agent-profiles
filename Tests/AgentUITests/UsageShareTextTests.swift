import Foundation
import Testing
@testable import AgentUI

struct UsageShareTextTests {
    @Test func liveLimitReadsItsShare() {
        let limit = UsageLimit(title: "Session", remaining: 58)
        #expect(UsageFormat.share(limit, showsUsed: false) == "58% left")
        #expect(UsageFormat.share(limit, showsUsed: true) == "42% used")
    }

    @Test func outdatedLimitIsUnknownButKeepsTheOldFigure() {
        let limit = UsageLimit(title: "Session", remaining: nil, lastSeen: 100)
        #expect(UsageFormat.share(limit, showsUsed: false) == "Unknown · was 100% left")
        #expect(UsageFormat.share(limit, showsUsed: true) == "Unknown · was 0% used")
    }

    @Test func limitWithNothingReported() {
        #expect(UsageFormat.share(UsageLimit(title: "Session", remaining: nil), showsUsed: false) == "No data yet")
    }

    @Test func outdatedLimitsGiveTheMenuBarAndAlertsNothingToUse() {
        var card = UsageCardModel(provider: .claude)
        card.limits = [UsageLimit(title: "Session", remaining: nil, lastSeen: 100),
                       UsageLimit(title: "Weekly", remaining: nil, lastSeen: 66)]
        #expect(card.sessionRemaining == nil)
        #expect(card.weeklyRemaining == nil)
        #expect(UsageFormat.compact(card.sessionRemaining, showsUsed: false) == "–")
    }
}
