import Foundation
import Testing
@testable import AgentUI

struct UsageLimitGroupTests {
    @Test func groupKeysAndNamesTheLimit() {
        let gemini = UsageLimit(title: "Weekly limit", remaining: 98, group: "Gemini Models")
        let claude = UsageLimit(title: "Weekly limit", remaining: 100, group: "Claude and GPT models")
        // Same title in two groups: still two rows, two alerts.
        #expect(gemini.id != claude.id)
        #expect(gemini.fullTitle == "Gemini Models · Weekly limit")
        #expect(UsageLimit(title: "Session", remaining: 50).fullTitle == "Session")
        #expect(UsageLimit(title: "Session", remaining: 50).id == "Session")
    }
}
