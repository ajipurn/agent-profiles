import Foundation
import ClaudeProfilesCore
import CodexProfilesCore

extension Commands {
    /// Checks the name here, so a typo fails fast with the choices, then hands
    /// the switch to the app and waits until it shows on disk. Where there is
    /// no app, only the Claude Code profile can switch: that is one file.
    func switchTo(_ provider: Provider, name: String, wait: Bool) async throws {
        let target: (urlName: String, shown: String, isDone: () -> Bool)
        switch provider {
        case .claude:
            let manager = claude
            guard manager.profiles().contains(name) else {
                throw unknown(name, provider, choices: manager.ordered(manager.profiles()))
            }
            target = (name, name, { manager.activeProfile() == name })

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
