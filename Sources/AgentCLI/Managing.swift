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

extension Commands {
    /// `login codex [name]`: adds a Codex account in this terminal, as the
    /// Mac app's Add Account does in Terminal. The login in use is kept in its
    /// saved account and comes back if the sign-in doesn't finish. Codex
    /// keeps the new login in auth.json (its file store), which switching needs.
    func loginCodex(name: String?) async throws {
        let switcher = codex
        guard let cli = CodexCLI.resolve() else {
            throw CLIError.failed("the codex CLI isn't installed; install it, then run this again")
        }
        let previous = try switcher.liveState().matchingProfileID
        try await switcher.prepareForNewLogin()
        context.errorOutput("Sign in to the ChatGPT account you want to add.")
        let status = Self.runInteractive(cli.executable, ["-c", #"cli_auth_credentials_store="file""#, "login"])
        guard status == 0, let file = try? switcher.liveState().file, file.identity != nil else {
            try await switcher.restoreAfterLogin(previousProfileID: previous)
            throw CLIError.failed("Codex sign-in didn't finish; the login you had is back")
        }
        let profile = try await switcher.completeNewLogin(name: name ?? (try switcher.suggestedName(for: file)))
        if json {
            return emit(["provider": Provider.codex.rawValue, "name": profile.displayName, "id": profile.id.uuidString,
                         "state": "saved"] as [String: Any])
        }
        context.output("Added Codex account “\(profile.displayName)”; it is the one in use now.")
    }

    /// Runs a program on this terminal, so it can ask and show a browser link.
    /// A Windows batch file (npm's codex.cmd) runs through cmd.
    static func runInteractive(_ executable: URL, _ arguments: [String]) -> Int32 {
        let process = Process()
        #if os(Windows)
        if ["cmd", "bat"].contains(executable.pathExtension.lowercased()) {
            let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
            process.executableURL = URL(fileURLWithPath: systemRoot + #"\System32\cmd.exe"#)
            process.arguments = ["/d", "/c", executable.path] + arguments
        } else {
            process.executableURL = executable
            process.arguments = arguments
        }
        #else
        process.executableURL = executable
        process.arguments = arguments
        #endif
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
