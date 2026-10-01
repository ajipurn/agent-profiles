import Foundation
import PlatformSupport

public enum SecureFile {
    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FilePermissions.set(0o700, at: url)
    }

    public static func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public static func atomicWrite(_ data: Data, to url: URL, mode: Int16 = 0o600) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: [.withoutOverwriting])
            try FilePermissions.set(mode, at: tmp)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            try FilePermissions.set(mode, at: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw SwitcherError.io(error.localizedDescription)
        }
    }

    public static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
