import Foundation
#if os(Windows)
import WinSDK
#endif

/// The user's own PATH, the part Windows keeps in HKEY_CURRENT_USER\Environment,
/// for putting a folder of ours in front: the claude shim only works ahead of
/// the real claude. Windows builds each new process's PATH from the machine's
/// entries followed by these, and terminals already open keep the PATH they
/// started with.
public enum UserPath {
    /// The registry key under HKEY_CURRENT_USER; tests use a scratch one.
    public static let environmentKey = "Environment"

    /// Whether `dir` is one of `path`'s entries, however it is spelled there.
    public static func contains(_ dir: String, in path: String) -> Bool {
        let folder = normalized(dir)
        return entries(path).contains { normalized($0) == folder }
    }

    /// `path` with `dir` as its first entry and no other spelling of it.
    public static func prepending(_ dir: String, to path: String) -> String {
        let folder = normalized(dir)
        return ([dir] + entries(path).filter { normalized($0) != folder }).joined(separator: ";")
    }

    /// `path` without `dir`, however it was spelled there.
    public static func removing(_ dir: String, from path: String) -> String {
        let folder = normalized(dir)
        return entries(path).filter { normalized($0) != folder }.joined(separator: ";")
    }

    static func entries(_ path: String) -> [String] {
        path.split(separator: ";").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// One spelling per folder: case, surrounding quotes and spaces, slashes,
    /// a trailing backslash and %VARIABLES% don't make it a different one.
    static func normalized(_ entry: String) -> String {
        var folder = expandingVariables(entry.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
            .replacingOccurrences(of: "/", with: "\\")
        while folder.hasSuffix("\\") { folder.removeLast() }
        return folder.lowercased()
    }

    static func expandingVariables(_ text: String) -> String {
        #if os(Windows)
        guard text.contains("%") else { return text }
        return text.withCString(encodedAs: UTF16.self) { source in
            let size = ExpandEnvironmentStringsW(source, nil, 0)
            guard size > 0 else { return text }
            var buffer = [WCHAR](repeating: 0, count: Int(size))
            let written = ExpandEnvironmentStringsW(source, &buffer, size)
            guard written > 0, written <= size else { return text }
            return String(decoding: buffer[..<(Int(written) - 1)], as: UTF16.self)
        }
        #else
        return text
        #endif
    }

    #if os(Windows)
    /// Whether `dir` is on the user's PATH.
    public static func contains(_ dir: URL, key: String = environmentKey) -> Bool {
        guard let path = try? read(key: key), let folder = try? Win32.path(dir) else { return false }
        return contains(folder, in: path)
    }

    /// Puts `dir` first on the user's PATH, moving it there if it was further back.
    public static func add(_ dir: URL, key: String = environmentKey) throws {
        let path = try read(key: key), folder = try Win32.path(dir)
        if let first = entries(path).first, normalized(first) == normalized(folder) { return }
        try write(prepending(folder, to: path), key: key)
    }

    public static func remove(_ dir: URL, key: String = environmentKey) throws {
        let path = try read(key: key), folder = try Win32.path(dir)
        guard contains(folder, in: path) else { return }
        try write(removing(folder, from: path), key: key)
    }

    /// As stored, %VARIABLES% unexpanded; empty when there is none yet.
    static func read(key: String) throws -> String {
        try Win32.registryString(key: key, value: "Path") ?? ""
    }

    static func write(_ path: String, key: String) throws {
        try Win32.setRegistryString(path, key: key, value: "Path")
        if key == environmentKey { Win32.announceEnvironmentChange() }
    }
    #endif
}
