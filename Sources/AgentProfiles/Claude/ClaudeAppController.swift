import AppKit
import UserNotifications

/// Claude.app lifecycle: locate, quit, relaunch. No AppleScript — plain NSWorkspace,
/// so no Automation permission prompt.
@MainActor
final class ClaudeAppController {
    let appURL: URL?
    let bundleID: String?
    /// Preview mode: behaves as if Claude quit and relaunched, without
    /// touching the real app.
    let isInert: Bool

    init(inert: Bool = false) {
        isInert = inert
        let candidates = [
            URL(fileURLWithPath: "/Applications/Claude.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app"),
        ]
        appURL = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        // Resolved from the bundle, not hardcoded (expected: com.anthropic.claudefordesktop).
        bundleID = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    var isRunning: Bool {
        guard !isInert, let bundleID else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Returns true when Claude ended up not running.
    func quit() async -> Bool {
        if isInert { return true }
        guard let bundleID else { return false }
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        guard !running.isEmpty else { return true }

        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return running.allSatisfy(\.isTerminated)
    }

    func relaunch() {
        guard !isInert, let appURL else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

}

enum Notifier {
    /// `userInfo` rides along to the app's notification delegate — the
    /// low-limit alerts use it to carry the suggested switch target.
    static func post(_ title: String, _ body: String = "", userInfo: [String: String] = [:]) {
        // UNUserNotificationCenter requires a real .app bundle; `swift run` has none.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            NSLog("[Agent Profiles] %@ — %@", title, body)
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            // Denied → degrade silently.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = userInfo
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
