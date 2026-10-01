import Foundation

public enum FilePermissions {
    /// Sets POSIX mode bits (0o600 secrets, 0o700 their dirs, 0o755 scripts).
    /// No-op on Windows: there is no mode to set, and files under the user's
    /// profile are already private to that user through inherited ACLs.
    public static func set(_ mode: Int16, at url: URL) throws {
        #if !os(Windows)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
        #endif
    }
}
