import Foundation
import Testing
@testable import ClaudeProfilesCore

final class AppVersionTests {
    @Test func testComparison() {
        #expect(AppVersion.isNewer("v1.2.0", than: "1.1.1"))
        #expect(AppVersion.isNewer("2.0", than: "1.9.9"))
        #expect(AppVersion.isNewer("1.1.1.1", than: "1.1.1"))
        #expect(!AppVersion.isNewer("v1.1.1", than: "1.1.1"))
        #expect(!AppVersion.isNewer("1.0.9", than: "1.1"))
        #expect(!AppVersion.isNewer("garbage", than: "1.1.1"))
    }
}
