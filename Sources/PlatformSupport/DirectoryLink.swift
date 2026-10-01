import Foundation

public enum PlatformError: LocalizedError, Equatable {
    case unsupported(String)
    case windows(code: UInt32, path: String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let what):
            return "\(what) is not supported on this platform yet."
        case .windows(let code, let path):
            return "Windows error \(code) at \(path)."
        }
    }
}

/// Every directory link the profile switcher makes goes through here, so the
/// link kind can differ per platform: symlinks on macOS, and on Windows (to
/// come) junctions, which need no admin rights or Developer Mode.
public enum DirectoryLink {
    /// lstat semantics: true for the link itself, dangling or not.
    public static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            == .typeSymbolicLink
    }

    /// The link's target exactly as stored (may be relative).
    public static func destination(of url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    public static func create(at url: URL, pointingTo target: URL) throws {
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    /// Atomically repoint `url` at `target`: the new link is created beside the
    /// old one and rename(2)d over it, so a crash mid-switch can never leave
    /// the path missing or dangling. `url` must be missing or already a link.
    public static func replace(at url: URL, pointingTo target: URL) throws {
        #if os(Windows)
        // rename cannot replace a directory entry here; needs a junction swap.
        throw PlatformError.unsupported("Switching the Claude data folder")
        #else
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".claude-link-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: tmp)
        try fm.createSymbolicLink(at: tmp, withDestinationURL: target)
        guard rename(tmp.path, url.path) == 0 else {
            let err = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        #endif
    }
}
