import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public enum Processes {
    /// Whether a process with this ID exists. A process of another user
    /// still counts.
    public static func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if os(Windows)
        let queryLimitedInformation: DWORD = 0x1000 // PROCESS_QUERY_LIMITED_INFORMATION
        let stillActive: DWORD = 259 // STILL_ACTIVE
        guard let handle = OpenProcess(queryLimitedInformation, false, DWORD(pid)) else { return false }
        defer { CloseHandle(handle) }
        var code: DWORD = 0
        return GetExitCodeProcess(handle, &code) && code == stillActive
        #else
        return kill(pid, 0) == 0 || errno == EPERM
        #endif
    }
}
