import Foundation
import Testing
@testable import PlatformSupport

struct UserPathTests {
    let shim = #"C:\Users\me\AppData\Roaming\Claude-Profiles\_cli\bin"#

    @Test func prependingPutsTheFolderFirstOnce() {
        #expect(UserPath.prepending(shim, to: "") == shim)
        #expect(UserPath.prepending(shim, to: #"C:\a;C:\b"#) == shim + #";C:\a;C:\b"#)
        // Already there in another spelling: moved to the front, and only once.
        let spelled = #"C:\a;"C:\USERS\me\AppData\Roaming\Claude-Profiles\_cli\bin\";C:\b;"#
        #expect(UserPath.prepending(shim, to: spelled) == shim + #";C:\a;C:\b"#)
    }

    @Test func containsAndRemovingIgnoreSpelling() {
        let path = #"C:\a;c:/users/me/appdata/roaming/claude-profiles/_cli/bin/;;C:\b"#
        #expect(UserPath.contains(shim, in: path))
        #expect(!UserPath.contains(#"C:\Users\me"#, in: path))
        #expect(UserPath.removing(shim, from: path) == #"C:\a;C:\b"#)
        #expect(!UserPath.contains(shim, in: UserPath.removing(shim, from: path)))
    }

    #if os(Windows)
    @Test func variablesExpandBeforeComparing() throws {
        let systemRoot = try #require(ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "SYSTEMROOT" })
        #expect(UserPath.contains(systemRoot.value + #"\System32"#, in: #"C:\a;%SystemRoot%\System32"#))
    }

    /// Against a scratch key, never the real HKEY_CURRENT_USER\Environment.
    @Test func addAndRemoveGoThroughTheRegistry() throws {
        let key = #"Software\AgentProfilesTests-"# + UUID().uuidString
        defer { Win32.deleteRegistryKey(key) }
        let dir = URL(fileURLWithPath: #"C:\Agent Profiles Test\bin"#)

        #expect(try UserPath.read(key: key) == "") // no key yet: an empty PATH
        #expect(!UserPath.contains(dir, key: key))
        try UserPath.add(dir, key: key)
        #expect(try UserPath.read(key: key) == #"C:\Agent Profiles Test\bin"#)

        // Other entries keep their order and their %VARIABLES%.
        try Win32.setRegistryString(#"C:\a;%SystemRoot%\System32;C:\Agent Profiles Test\bin\"#, key: key, value: "Path")
        try UserPath.add(dir, key: key)
        #expect(try UserPath.read(key: key) == #"C:\Agent Profiles Test\bin;C:\a;%SystemRoot%\System32"#)
        #expect(UserPath.contains(dir, key: key))

        try UserPath.remove(dir, key: key)
        #expect(try UserPath.read(key: key) == #"C:\a;%SystemRoot%\System32"#)
        #expect(!UserPath.contains(dir, key: key))
    }
    #endif
}
