# Windows port

Agent Profiles on Windows is two programs in one folder:

- **`agent-profiles.exe`**, the engine. It is the Swift CLI, built from the
  same cores as the Mac app (`ClaudeProfilesCore`, `CodexProfilesCore`,
  `ProvidersCore`, `UsageCostCore`, `UsageHistoryCore`). Every command
  answers with `--json`.
- **`AgentProfiles.exe`**, the tray app. It is C#/.NET 8 WPF, in `windows/`.
  It owns timing, settings and drawing:
  - It runs the engine once per read or action.
  - It renders the JSON: tray icon, panel, settings and notifications.
  - It never touches the profile folders itself.

The engine runs once per command, not as a long-lived daemon. A crash is
contained to one command, nothing has to stay in sync, and the commands stay
useful from a terminal. The tray serializes its calls, so two engine runs
never write the same store at once.

## What the tray reads

| Command | Gives |
| --- | --- |
| `status --json` | The active Claude Desktop profile, the Claude Code profile and the Codex account. |
| `list --json` | The saved profiles and accounts. |
| `usage --json [--all-codex] [--record]` | Claude usage from each profile's cache, and Codex usage. Codex is the active account, or every saved account with `--all-codex`. A failing part is reported as an error inside its own section; the command does not fail as a whole. With `--record`, the readings are appended to `usage-history.jsonl`. |
| `providers --json [usage] [id …]` | Extra providers (Gemini, Antigravity, Copilot, …): signed in or not, and their usage. |
| `cost --json` | Estimated cost today, yesterday and over 30 days. |
| `history --json` | Peaks and readings over the last days. |
| `switch … --json` | Switches Claude Desktop, Claude Code or Codex. On Windows the engine does it itself, since there is no Mac app to hand it to. |

With `--json`, a failure prints `{"error": "…"}` to stdout and exits 1.

## Phases

0. **Facts.** Run `scripts/windows-research.ps1` on a Windows PC with Claude
   Desktop, Claude Code and Codex signed in. It answers:
   - which cache format Claude Desktop uses (Chromium simple cache or blockfile),
   - whether Claude is a Squirrel or MSIX install,
   - where Claude Code keeps its login,
   - Codex's paths.
1. **Engine foundations.** These can be tested on macOS and in Windows CI:
   - provider usage,
   - `usage` that survives a signed-out Codex,
   - Codex usage for every saved account,
   - history recording,
   - JSON errors,
   - `CODEX_HOME`,
   - `Processes.isRunning` on Windows.
2. **Windows switching.** This needs phase 0:
   - Claude Desktop: find and close `claude.exe` (every process of it), switch, relink shared history, relaunch.
   - Codex: the same for the ChatGPT/Codex app, with `AccountSwitcher` and a Windows client controller.
   - Claude Code: a `claude.cmd` shim on PATH in place of the POSIX one.
   - Codex sign-in: in a console window, with file credential storage.
3. **Tray app.**
   - Tray icon: two bars (session, weekly); the tooltip carries the numbers.
   - Panel by the tray: cost, provider tabs, usage cards, accounts to switch to.
   - Settings window, toasts and launch at sign-in.
4. **Shipping.**
   - CI builds the engine (release) with its Swift runtime DLLs and `dotnet publish`es the tray. The result is one zip artifact to test.
   - Later: an installer, code signing and updates.

## Open questions

- If Claude Desktop on Windows uses Chromium's blockfile cache, `UsageReader`
  needs a reader for that format before Claude usage shows.
- An MSIX install keeps Claude's data under
  `%LOCALAPPDATA%\Packages\<package>\LocalCache\Roaming\Claude`.
  Profile links then have to live there.
- Antigravity's sign-in on Windows is probably in Credential Manager (go-keyring).
  It is not read yet.
- Cursor, OpenCode and Kiro need SQLite, which the Windows Swift build may not
  have. Without it they fall back or report unsupported.
