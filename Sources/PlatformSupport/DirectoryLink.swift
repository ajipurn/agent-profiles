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

/// Every directory link the profile switcher makes, reads or removes goes
/// through here, so the link kind can differ per platform: symlinks on
/// macOS, junctions on Windows (they need no admin rights or Developer Mode).
public enum DirectoryLink {
    /// True for the link itself, dangling or not.
    public static func isLink(_ url: URL) -> Bool {
        #if os(Windows)
        guard let path = try? Win32.path(url) else { return false }
        return Win32.linkTarget(path) != nil
        #else
        // lstat semantics: attributesOfItem does not follow the final link.
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            == .typeSymbolicLink
        #endif
    }

    /// Where the link points, as an absolute URL (relative symlinks are
    /// resolved against the link's folder).
    public static func destination(of url: URL) throws -> URL {
        #if os(Windows)
        let path = try Win32.path(url)
        guard let target = Win32.linkTarget(path) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return URL(fileURLWithPath: target)
        #else
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        return URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        #endif
    }

    public static func create(at url: URL, pointingTo target: URL) throws {
        #if os(Windows)
        let path = try Win32.path(url)
        try Win32.createDirectory(path)
        do {
            try Win32.setJunction(path, target: try Win32.path(target))
        } catch {
            _ = try? Win32.removeLink(path) // still a plain empty directory
            throw error
        }
        #else
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #endif
    }

    /// Repoint `url` at `target` without the path ever going missing or
    /// dangling, even on a crash mid-switch. `url` must be missing or a link.
    public static func replace(at url: URL, pointingTo target: URL) throws {
        #if os(Windows)
        let path = try Win32.path(url)
        if Win32.linkTarget(path) != nil {
            // A junction takes the new target in place. A symlink can't take
            // junction data; swap that one the slow way (briefly missing).
            do { return try Win32.setJunction(path, target: try Win32.path(target)) } catch {}
            try Win32.removeLink(path)
        }
        try create(at: url, pointingTo: target)
        #else
        // The new link is created beside the old one and rename(2)d over it.
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

    /// Removes the link only; what it points to is untouched.
    public static func remove(at url: URL) throws {
        #if os(Windows)
        try Win32.removeLink(try Win32.path(url))
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }

    /// Removes `url` and everything under it, but only unlinks the links it
    /// meets — never what they point to (shared history lives behind them).
    public static func removeTree(at url: URL) throws {
        #if os(Windows)
        // Foundation's recursive delete is not trusted to stop at junctions.
        if isLink(url) { return try remove(at: url) }
        let fm = FileManager.default
        if (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory {
            for name in try fm.contentsOfDirectory(atPath: url.path) {
                try removeTree(at: url.appendingPathComponent(name))
            }
        }
        try fm.removeItem(at: url)
        #else
        // Never follows symlinks here.
        try FileManager.default.removeItem(at: url)
        #endif
    }

    /// `url` with its links followed.
    public static func resolvingLinks(_ url: URL) -> URL {
        #if os(Windows)
        // Only the last component can be a link in the trees this app builds.
        var current = url
        for _ in 0..<32 {
            guard let next = try? destination(of: current) else { break }
            current = next
        }
        return current
        #else
        return url.resolvingSymlinksInPath()
        #endif
    }
}
