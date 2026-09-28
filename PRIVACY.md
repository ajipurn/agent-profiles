# Privacy

Agent Profiles has no analytics or advertising SDK. Sparkle system profiling is disabled.

The two providers work differently, and so does what the app touches for each.

## Claude

- Profiles are folders under `~/Library/Application Support/Claude-Profiles/`. `~/Library/Application Support/Claude` becomes a link to the active one. Claude Code (CLI) profiles live in `Claude-Profiles/_cli/`.
- The app never reads Claude passwords, cookies or tokens. It moves and links these folders, and reads a few of Claude's own local files: its config, and its HTTP cache for the usage numbers.
- Claude usage is read from that local cache, so Claude needs no network requests from this app.
- Shared session history makes a timestamped backup in your home folder before merging anything.

## Codex

- The active Codex login is read from `~/.codex/auth.json`. Saved login snapshots and account metadata are stored under `~/Library/Application Support/CodexProfiles/profiles`, preferences in `CodexProfiles/settings.json`.
- Saved login snapshots contain authentication tokens. They use restricted file permissions and are not encrypted by this app. Profile metadata contains no access or refresh tokens.
- A signed-in login that is not saved yet is saved automatically, like choosing Save Current Account.
- Codex usage is requested from `chatgpt.com`; token refreshes use `auth.openai.com`. These requests use the relevant account's credentials.
- Adding an account runs the installed Codex CLI's normal sign-in in Terminal.

## App updates

Update checks and downloads use GitHub and its release-asset infrastructure. GitHub receives normal connection information, including your IP address. No account credentials or profile data are sent. Automatic update checks can be turned off in Settings; automatic installation is opt-in.

## Removal

Deleting a Claude profile removes its folder, which logs that account out; a Claude Code login token stays in your Keychain until you remove it. Removing a saved Codex account deletes its saved credentials and metadata; the live Codex login stays signed in. Uninstalling the app deletes neither folder above.

Preview mode (`--demo`) uses disposable sample data and disables real sign-in, client restarts, usage requests and app updates.
