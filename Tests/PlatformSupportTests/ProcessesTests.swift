import Foundation
import Testing
@testable import PlatformSupport

struct ProcessesTests {
    @Test func tellsRunningFromGone() {
        #expect(Processes.isRunning(ProcessInfo.processInfo.processIdentifier))
        #expect(!Processes.isRunning(0))
        #expect(!Processes.isRunning(-1))
        #if !os(Windows)
        #expect(!Processes.isRunning(Int32.max))
        #endif
    }
}
