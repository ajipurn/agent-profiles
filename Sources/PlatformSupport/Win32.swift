#if os(Windows)
import Foundation
import WinSDK

/// The Win32 plumbing behind DirectoryLink and FileReplacement. The values
/// below are spelled out because Swift's WinSDK import leaves them out:
/// they are CTL_CODE macros, or live in the driver kit's ntifs.h.
enum Win32 {
    static let genericRead: DWORD = 0x8000_0000
    static let genericWrite: DWORD = 0x4000_0000
    static let shareAll: DWORD = 0x7 // read | write | delete
    static let openExisting: DWORD = 3
    static let backupSemantics: DWORD = 0x0200_0000 // required to open a directory
    static let openReparsePoint: DWORD = 0x0020_0000 // the link itself, not its target
    static let attributeDirectory: DWORD = 0x10
    static let attributeReparsePoint: DWORD = 0x400
    static let invalidAttributes: DWORD = 0xFFFF_FFFF
    static let setReparsePoint: DWORD = 0x0009_00A4
    static let getReparsePoint: DWORD = 0x0009_00A8
    static let tagMountPoint: UInt32 = 0xA000_0003 // a junction
    static let tagSymlink: UInt32 = 0xA000_000C
    static let maxReparseSize = 16 * 1024

    /// The native path, "C:\dir\name". URL.path may spell a drive as
    /// "/C:/dir/name", which Win32 calls (and junction targets) reject.
    static func path(_ url: URL) throws -> String {
        try url.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { throw CocoaError(.fileReadInvalidFileName) }
            var path = String(cString: representation).replacingOccurrences(of: "/", with: "\\")
            if path.hasPrefix("\\"), path.dropFirst(2).first == ":" { path.removeFirst() }
            return path
        }
    }

    static func lastError(_ path: String) -> PlatformError {
        .windows(code: GetLastError(), path: path)
    }

    static func attributes(_ path: String) -> DWORD {
        path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
    }

    /// Opens the link itself, never what it points to.
    static func openLink(_ path: String, write: Bool) throws -> HANDLE {
        let access = write ? genericRead | genericWrite : genericRead
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, access, shareAll, nil, openExisting, backupSemantics | openReparsePoint, nil)
        }
        guard let handle, handle != HANDLE(bitPattern: -1) else { throw lastError(path) }
        return handle
    }

    /// Where the junction or symlink at `path` points; nil for anything else,
    /// including other reparse points such as OneDrive placeholders.
    static func linkTarget(_ path: String) -> String? {
        let attributes = attributes(path)
        guard attributes != invalidAttributes, attributes & attributeReparsePoint != 0,
              let handle = try? openLink(path, write: false) else { return nil }
        defer { _ = CloseHandle(handle) }

        var buffer = [UInt8](repeating: 0, count: maxReparseSize)
        var returned: DWORD = 0
        let read = buffer.withUnsafeMutableBytes {
            DeviceIoControl(handle, getReparsePoint, nil, 0, $0.baseAddress, DWORD($0.count), &returned, nil)
        }
        guard read, returned >= 16 else { return nil }

        // REPARSE_DATA_BUFFER: tag u32, data length u16, reserved u16, then
        // substitute name offset/length and print name offset/length (u16
        // each, in bytes into PathBuffer). Symlinks add a u32 of flags.
        func u16(_ at: Int) -> Int { Int(buffer[at]) | Int(buffer[at + 1]) << 8 }
        let tag = UInt32(u16(0)) | UInt32(u16(2)) << 16
        let pathBuffer: Int
        switch tag {
        case tagMountPoint: pathBuffer = 16
        case tagSymlink: pathBuffer = 20
        default: return nil
        }
        func name(offset: Int, length: Int) -> String? {
            let start = pathBuffer + offset
            guard length > 0, start + length <= Int(returned) else { return nil }
            let units = stride(from: start, to: start + length, by: 2).map { UInt16(u16($0)) }
            return String(decoding: units, as: UTF16.self)
        }
        if let print = name(offset: u16(12), length: u16(14)) { return print }
        // No print name: fall back to the NT form, "\??\C:\dir".
        guard var substitute = name(offset: u16(8), length: u16(10)) else { return nil }
        if substitute.hasPrefix("\\??\\") { substitute.removeFirst(4) }
        return substitute
    }

    /// Makes the empty directory at `path` a junction to `target`. On an
    /// existing junction this rewrites the target in one call, so the path
    /// never goes missing.
    static func setJunction(_ path: String, target: String) throws {
        let substitute = Array(("\\??\\" + target).utf16)
        let print = Array(target.utf16)
        let names = substitute + [0] + print + [0]

        var buffer: [UInt8] = []
        func append(_ value: Int) { buffer += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        append(Int(tagMountPoint & 0xFFFF))
        append(Int(tagMountPoint >> 16))
        append(8 + names.count * 2) // data length: the four u16s below + PathBuffer
        append(0)
        append(0)
        append(substitute.count * 2)
        append((substitute.count + 1) * 2)
        append(print.count * 2)
        for unit in names { append(Int(unit)) }

        let handle = try openLink(path, write: true)
        defer { _ = CloseHandle(handle) }
        var returned: DWORD = 0
        let written = buffer.withUnsafeMutableBytes {
            DeviceIoControl(handle, setReparsePoint, $0.baseAddress, DWORD($0.count), nil, 0, &returned, nil)
        }
        guard written else { throw lastError(path) }
    }

    static func createDirectory(_ path: String) throws {
        guard path.withCString(encodedAs: UTF16.self, { CreateDirectoryW($0, nil) }) else { throw lastError(path) }
    }

    /// Removes a link without touching what it points to.
    static func removeLink(_ path: String) throws {
        let isDirectory = attributes(path) & attributeDirectory != 0
        let removed = path.withCString(encodedAs: UTF16.self) {
            isDirectory ? RemoveDirectoryW($0) : DeleteFileW($0)
        }
        guard removed else { throw lastError(path) }
    }
}
#endif
