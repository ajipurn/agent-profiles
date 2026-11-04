import Foundation
import Testing
@testable import ProvidersCore

@Suite struct ProviderSnapshotTests {
    @Test func windowClampsUsedShare() {
        #expect(ProviderWindow(title: "x", usedPercent: 140).usedPercent == 100)
        #expect(ProviderWindow(title: "x", usedPercent: -3).remainingPercent == 100)
        #expect(ProviderWindow(title: "x", usedPercent: .nan).usedPercent == 0)
    }
}
