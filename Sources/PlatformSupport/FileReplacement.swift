import Foundation
#if os(Windows)
import WinSDK
#endif

public enum FileReplacement {
    /// Moves `replacement` over the existing file at `url` in one step.
    /// Foundation's replaceItemAt traps on Windows ("not yet implemented"),
    /// so there MoveFileExW does it, flushed before it returns.
    public static func replaceItem(at url: URL, withItemAt replacement: URL) throws {
        #if os(Windows)
        let source = try Win32.path(replacement)
        let destination = try Win32.path(url)
        let moved = source.withCString(encodedAs: UTF16.self) { source in
            destination.withCString(encodedAs: UTF16.self) { destination in
                MoveFileExW(source, destination, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        guard moved else { throw Win32.lastError(destination) }
        #else
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        #endif
    }
}
