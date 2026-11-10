import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum Processes {
    /// Whether a process with this ID exists. A process of another user
    /// still counts. Windows can't tell here and says yes.
    public static func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if os(Windows)
        return true
        #else
        return kill(pid, 0) == 0 || errno == EPERM
        #endif
    }
}
