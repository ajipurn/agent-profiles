import AppKit

/// Claude Profiles and Codex Profiles manage the same files as this app (the
/// ~/Library/Application Support/Claude symlink, ~/.codex/auth.json). Two
/// managers switching them at once can strand a login, so the merged app does
/// not start next to either.
@MainActor
enum LegacyAppGuard {
    private static let legacyApps = [
        (bundleID: "dev.local.ClaudeProfiles", name: "Claude Profiles"),
        (bundleID: "dev.aji.CodexProfiles", name: "Codex Profiles"),
    ]

    /// True when no legacy app is running, or the user agreed to quit them
    /// and they did.
    static func clearToLaunch() -> Bool {
        let running = legacyApps.compactMap { legacy -> (name: String, apps: [NSRunningApplication])? in
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: legacy.bundleID)
            return apps.isEmpty ? nil : (legacy.name, apps)
        }
        guard !running.isEmpty else { return true }

        let names = running.map(\.name).joined(separator: " and ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(names) \(running.count == 1 ? "is" : "are") still running"
        alert.informativeText = "Agent Profiles manages the same accounts. Two apps switching them "
            + "at the same time can lose a login, so quit \(names) to continue."
        alert.addButton(withTitle: "Quit \(names)")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let apps = running.flatMap(\.apps)
        apps.forEach { $0.terminate() }
        // isTerminated updates on the main run loop, so spin it while waiting.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, apps.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard apps.allSatisfy(\.isTerminated) else {
            let failed = NSAlert()
            failed.messageText = "\(names) did not quit"
            failed.informativeText = "Quit it yourself, then open Agent Profiles again."
            failed.runModal()
            return false
        }
        return true
    }
}
