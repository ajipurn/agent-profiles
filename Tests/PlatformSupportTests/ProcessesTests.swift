import Foundation
import Testing
@testable import PlatformSupport

struct ProcessesTests {
    @Test func tellsRunningFromGone() {
        #expect(Processes.isRunning(ProcessInfo.processInfo.processIdentifier))
        #expect(!Processes.isRunning(0))
        #expect(!Processes.isRunning(-1))
        #expect(!Processes.isRunning(Int32.max))
    }
}
