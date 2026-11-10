import Foundation
#if os(macOS)
import Security
#endif

/// Passwords that Go programs keep in the login Keychain with go-keyring
/// (github.com/zalando/go-keyring). go-keyring saves through
/// `/usr/bin/security`, so the item's access list trusts that tool alone:
/// reading the password through the tool never prompts, where the Security
/// framework from this app would. Other platforms report nothing.
public enum GoKeyring {
    /// Whether the item exists. Reads attributes only, which never prompts.
    public static func contains(service: String, account: String) -> Bool {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    /// The item's password, decoded, or nil when it is missing or unreadable.
    public static func password(service: String, account: String) -> String? {
        stored(service: service, account: account).flatMap(decode)
    }

    /// The item's password as stored, not decoded: what `set` takes back.
    public static func stored(service: String, account: String) -> String? {
        #if os(macOS)
        guard let output = runSecurity(["find-generic-password", "-s", service, "-a", account, "-w"]),
              let text = String(data: output, encoding: .utf8) else { return nil }
        let stored = text.trimmingCharacters(in: .newlines)
        return stored.isEmpty ? nil : stored
        #else
        return nil
        #endif
    }

    /// Creates or replaces the item the way go-keyring does: through
    /// `/usr/bin/security`, so the item keeps trusting that tool alone and
    /// Go programs and this app both read it without a prompt. The password
    /// goes in on standard input, never on a command line that `ps` shows.
    /// `stored` is a stored form (see `encode`); it is read back to confirm.
    public static func set(_ stored: String, service: String, account: String) throws {
        #if os(macOS)
        let fields = [service, account, stored]
        // `security -i` splits its line on spaces; single quotes keep each
        // field whole, so a field may not hold one, nor a line break.
        guard fields.allSatisfy({ !$0.isEmpty && !$0.contains("'") && !$0.contains(where: \.isNewline) }) else {
            throw KeychainError.unsupportedValue
        }
        let command = "add-generic-password -U -s '\(service)' -a '\(account)' -w '\(stored)'\n"
        // security's interactive line limit (go-keyring checks the same).
        guard command.utf8.count <= 4096 else { throw KeychainError.unsupportedValue }
        guard runSecurity(["-i"], input: Data(command.utf8)) != nil,
              self.stored(service: service, account: account) == stored else {
            throw KeychainError.writeFailed
        }
        #else
        throw KeychainError.unavailable
        #endif
    }

    /// Removes the item. Missing is fine.
    public static func delete(service: String, account: String) throws {
        #if os(macOS)
        _ = runSecurity(["delete-generic-password", "-s", service, "-a", account])
        guard stored(service: service, account: account) == nil else { throw KeychainError.writeFailed }
        #else
        throw KeychainError.unavailable
        #endif
    }

    /// go-keyring's current stored form of a password.
    public static func encode(_ password: String) -> String {
        "go-keyring-base64:" + Data(password.utf8).base64EncodedString()
    }

    public enum KeychainError: Error, Equatable, LocalizedError {
        case unsupportedValue, writeFailed, unavailable

        public var errorDescription: String? {
            switch self {
            case .unsupportedValue: "The sign-in is too large or malformed to keep in the Keychain."
            case .writeFailed: "The login Keychain couldn't be changed. Unlock it and try again."
            case .unavailable: "There is no Keychain on this system."
            }
        }
    }

    /// go-keyring's stored forms: `go-keyring-base64:` (current),
    /// `go-keyring-encoded:` (hex, older releases), or the plain password.
    public static func decode(_ stored: String) -> String? {
        if let body = stored.removingPrefix("go-keyring-base64:") {
            guard let data = Data(base64Encoded: String(body)) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if let body = stored.removingPrefix("go-keyring-encoded:") {
            var bytes: [UInt8] = []
            var index = body.startIndex
            while index < body.endIndex {
                let next = body.index(index, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
                guard let byte = UInt8(body[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return String(bytes: bytes, encoding: .utf8)
        }
        return stored
    }

    #if os(macOS)
    /// Output of a successful `security` run. A tool that doesn't answer in
    /// time (a locked Keychain asking to be unlocked) is stopped.
    private static func runSecurity(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        if let input, let stdin {
            // A command line is far smaller than the pipe buffer.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        // A password is far smaller than the pipe buffer, so waiting first can't stall the tool.
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
    #endif
}

private extension String {
    func removingPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
