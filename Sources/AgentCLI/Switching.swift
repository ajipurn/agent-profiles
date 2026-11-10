import Foundation
import ClaudeProfilesCore
import CodexProfilesCore

extension Commands {
    /// Checks the name here, so a typo fails fast with the choices, then hands
    /// the switch to the app and waits until it shows on disk. Where there is
    /// no Mac app (Windows), the command switches by itself, as the app would.
    func switchTo(_ provider: Provider, name: String, wait: Bool) async throws {
        let target: (urlName: String, shown: String, isDone: () -> Bool)
        switch provider {
        case .claude:
            let manager = claude
            guard manager.profiles().contains(name) else {
                throw unknown(name, provider, choices: manager.ordered(manager.profiles()))
            }
            target = (name, name, { manager.activeProfile() == name })
            if context.openInApp == nil, !target.isDone() {
                guard let desktop = context.claudeDesktop else {
                    throw CLIError.failed("switching \(provider.title) isn't supported on this system yet")
                }
                return try await switchClaudeDesktop(to: name, quitting: desktop)
            }

        case .claudeCLI:
            let manager = claudeCode
            let profile: String? = name.caseInsensitiveCompare("default") == .orderedSame ? nil : name
            if let profile, !claudeCodeNames().contains(profile) {
                throw unknown(name, provider, choices: ["default"] + claudeCodeNames())
            }
            target = (profile ?? "Default", profile ?? "default", { manager.activeProfile() == profile })
            if context.openInApp == nil, !target.isDone() {
                // No app to ask: do what it would, the config folder made on first use.
                if let profile, !manager.profiles().contains(profile) { try manager.createProfile(name: profile) }
                try manager.setActive(profile)
                return report(provider, target.shown, state: "switched",
                              "\(provider.title) switched to \(target.shown). Applies to claude commands started from now on.")
            }

        case .codex:
            let switcher = codex
            let profiles = try codexProfiles()
            let matches = profiles.filter { $0.matches(name) }
            guard let profile = matches.first else {
                throw unknown(name, provider, choices: profiles.map(\.displayName))
            }
            guard matches.count == 1 else {
                throw CLIError.failed("several Codex accounts are called “\(name)”; use the email instead")
            }
            target = (name, profile.displayName, { (try? switcher.liveState())?.matchingProfileID == profile.id })
            if context.openInApp == nil, !target.isDone() {
                // The codex CLI reads the login at every start; an open app keeps the old one.
                try await switcher.switchTo(profile.id)
                return report(provider, profile.displayName, state: "switched",
                              "Codex switched to \(profile.displayName). Restart the ChatGPT or Codex app to use it there.")
            }
        }

        if target.isDone() {
            return report(provider, target.shown, state: "active", "\(provider.title) is on \(target.shown).")
        }
        guard let openInApp = context.openInApp else {
            throw CLIError.failed("switching \(provider.title) needs the Agent Profiles app, which runs on macOS only so far")
        }
        try openInApp(try Self.appURL(provider, target.urlName))
        guard wait else {
            return report(provider, target.shown, state: "requested",
                          "Asked Agent Profiles to switch \(provider.title) to \(target.shown).")
        }
        guard await waitUntil(target.isDone) else {
            throw CLIError.failed("""
                Agent Profiles has not switched \(provider.title) to \(target.shown) yet; \
                its notification or the app says what is holding it up
                """)
        }
        report(provider, target.shown, state: "switched", "\(provider.title) switched to \(target.shown)."
               + (provider == .claudeCLI ? " Applies to claude commands started from now on." : ""))
    }

    /// What the Mac app does for a Desktop switch: Claude quits, the profile
    /// link moves, shared history is relinked (only safe while Claude is
    /// down), and Claude starts again.
    func switchClaudeDesktop(to name: String, quitting desktop: any DesktopAppControl) async throws {
        let manager = claude
        let previous = manager.activeProfile()
        guard try await desktop.quit() else {
            throw CLIError.failed("Claude did not quit, so it stays on \(previous ?? "its profile")")
        }
        do {
            try manager.switchTo(name: name)
        } catch {
            try? desktop.launch()
            throw CLIError.failed("Claude Desktop could not switch to \(name): \(error.localizedDescription)")
        }
        var note = ""
        if manager.sharedHistoryEnabled {
            do { try manager.enableSharedHistory(promoteActive: true) }
            catch { note = " Shared history could not be relinked: \(error.localizedDescription)" }
        }
        try desktop.launch()
        report(.claude, name, state: "switched", "Claude Desktop switched to \(name)." + note)
    }

    /// The URL the app's scripting hook takes: agentprofiles://<provider>/<name>.
    static func appURL(_ provider: Provider, _ name: String) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/") // a name is one path component
        var components = URLComponents()
        components.scheme = "agentprofiles"
        components.host = provider.rawValue
        components.percentEncodedPath = "/" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
        guard let url = components.url else { throw CLIError.failed("“\(name)” can't be put in a URL") }
        return url
    }

    func waitUntil(_ isDone: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(context.switchTimeout)
        while !isDone() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: UInt64(max(0, context.pollInterval) * 1_000_000_000))
        }
        return true
    }

    func report(_ provider: Provider, _ name: String, state: String, _ text: String) {
        if json {
            emit(["provider": provider.rawValue, "name": name, "state": state] as [String: Any])
        } else {
            context.output(text)
        }
    }

    func unknown(_ name: String, _ provider: Provider, choices: [String]) -> CLIError {
        .failed("no \(provider.title) profile named “\(name)”; "
            + (choices.isEmpty ? "there are none yet" : "choose from " + choices.joined(separator: ", ")))
    }
}
