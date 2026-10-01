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
        // The file system representation is the native path; URL.path may
        // spell a drive as "/C:/", which Win32 calls don't accept.
        let moved = try replacement.withUnsafeFileSystemRepresentation { source in
            try url.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { throw CocoaError(.fileWriteInvalidFileName) }
                return String(cString: source).withCString(encodedAs: UTF16.self) { source in
                    String(cString: destination).withCString(encodedAs: UTF16.self) { destination in
                        MoveFileExW(source, destination, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                    }
                }
            }
        }
        guard moved else { throw PlatformError.windows(code: GetLastError(), path: url.path) }
        #else
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        #endif
    }
}
