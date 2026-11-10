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
        #if os(macOS)
        guard let output = runSecurity(["find-generic-password", "-s", service, "-a", account, "-w"]),
              let text = String(data: output, encoding: .utf8) else { return nil }
        return decode(text.trimmingCharacters(in: .newlines))
        #else
        return nil
        #endif
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
    private static func runSecurity(_ arguments: [String], timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
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
