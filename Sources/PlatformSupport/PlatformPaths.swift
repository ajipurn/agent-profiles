import Foundation

/// Where per-user app data lives, derived from a home directory so every
/// core stays testable against a fake home.
public enum PlatformPaths {
    /// `appData` relative to the home directory — also what shell scripts
    /// put after `$HOME/`.
    /// macOS: `Library/Application Support`. Windows: `AppData/Roaming`
    /// (the default `%APPDATA%`; redirected profiles are not handled yet).
    /// Elsewhere: `.config`, so the cores build and test on Linux CI.
    public static var appDataRelativePath: String {
        #if os(macOS)
        "Library/Application Support"
        #elseif os(Windows)
        "AppData/Roaming"
        #else
        ".config"
        #endif
    }

    /// The per-user data root that Electron calls `appData` — the parent of
    /// Claude Desktop's own data dir, and where this app keeps its stores.
    public static func appData(home: URL) -> URL {
        home.appendingPathComponent(appDataRelativePath, isDirectory: true)
    }
}
