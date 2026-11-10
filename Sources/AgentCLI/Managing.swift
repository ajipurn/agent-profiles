import Foundation
import ClaudeProfilesCore
import CodexProfilesCore

/// Setting profiles up, which the Mac app does from its menu: here for a
/// host without that app (the Windows tray) and for scripts.
extension Commands {
    /// `setup claude <name>`: the Claude Desktop login in use becomes the
    /// first profile, while Claude is closed. `setup claude-cli`: installs the
    /// `claude` shim that picks the Claude Code profile.
    func setup(_ provider: Provider, name: String?) async throws {
        switch provider {
        case .claude:
            guard let name else { throw CLIError.usage("setup claude takes a name for the account in use, e.g. setup claude main") }
            let manager = claude
            guard manager.profiles().isEmpty else {
                return report(.claude, manager.activeProfile() ?? name, state: "active", "Claude Desktop profiles are set up already.")
            }
            guard let desktop = context.claudeDesktop else {
                throw CLIError.failed("set Claude Desktop profiles up in the Agent Profiles app")
            }
            guard try await desktop.quit() else { throw CLIError.failed("Claude did not quit, so nothing was set up") }
            do {
                try manager.migrate(name: name)
            } catch {
                try? desktop.launch()
                throw CLIError.failed("Claude Desktop profiles could not be set up: \(error.localizedDescription)")
            }
            try desktop.launch()
            report(.claude, name, state: "set up", "Claude Desktop profiles are set up; the account in use is “\(name)”.")

        case .claudeCLI:
            guard name == nil else { throw CLIError.usage("setup claude-cli takes no name") }
            let manager = claudeCode
            try manager.installShim()
            #if os(Windows)
            let shim = manager.windowsShim.path, pathCommand = CLIProfileManager.windowsPathLine
            let how = "Put it first on your PATH with this PowerShell line, then open a new terminal:"
            #else
            let shim = manager.shim.path, pathCommand = CLIProfileManager.pathLine
            let how = "Put it first on your PATH with this line in ~/.zshrc, then open a new terminal:"
            #endif
            if json { return emit(["shim": shim, "pathCommand": pathCommand]) }
            context.output("Installed the claude profile shim at \(shim).\n\(how)\n  \(pathCommand)")

        case .codex:
            throw CLIError.usage("Codex needs no setup; sign in with codex login, then save codex <name>")
        }
    }

    /// `new claude|claude-cli <name>`: an empty profile that logs in on first use.
    func newProfile(_ provider: Provider, name: String) throws {
        switch provider {
        case .claude:
            let manager = claude
            let created = try manager.createProfile(name: name)
            try? manager.saveOrder(manager.savedOrder().filter { $0 != created } + [created])
            report(.claude, created, state: "created", "Created Claude Desktop profile “\(created)”; it logs in on first use.")
        case .claudeCLI:
            let created = try claudeCode.createProfile(name: name)
            report(.claudeCLI, created, state: "created", "Created Claude Code profile “\(created)”; it logs in on first use.")
        case .codex:
            throw CLIError.usage("Codex accounts come from a sign-in: codex login, then save codex <name>")
        }
    }

    /// `save codex <name>`: keeps the Codex login in use as a saved account.
    func save(_ provider: Provider, name: String) throws {
        guard provider == .codex else { throw CLIError.usage("only codex logins are saved; use new for Claude profiles") }
        let switcher = codex
        guard let file = try switcher.liveState().file else {
            throw CLIError.failed("Codex is signed out; sign in with codex login first")
        }
        guard file.isChatGPTSession else {
            throw CLIError.failed("Codex is signed in with an API key, which isn't saved as an account")
        }
        let profile = try switcher.saveCurrent(name: name)
        if json {
            return emit(["provider": provider.rawValue, "name": profile.displayName, "id": profile.id.uuidString,
                         "state": "saved"] as [String: Any])
        }
        context.output("Saved the Codex login in use as “\(profile.displayName)”.")
    }
}
