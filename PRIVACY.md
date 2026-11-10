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

## More providers

Gemini, Antigravity, Cursor, GitHub Copilot, OpenCode, Kiro and Grok are off until turned on in Settings → More Providers. A provider that is on reads the sign-in its own app or CLI keeps on this Mac and sends that token only to its own service, to ask for usage. It never writes to those files or databases: a token refreshed for a request stays in memory. The one exception is switching Antigravity accounts, below. Nothing is read from browser cookies, and nothing from the Keychain except Antigravity's item below and this app's own copies of it, all through macOS's own `security` tool, which those items trust (no prompt).


| Provider | Reads | Sends it to |
| --- | --- | --- |
| Gemini | `~/.gemini/oauth_creds.json` (Gemini CLI's Google sign-in), and the OAuth client in the installed Gemini CLI to renew it | `cloudcode-pa.googleapis.com`, `oauth2.googleapis.com` |
| Antigravity | The Keychain item `gemini` / `antigravity` (the sign-in the Antigravity app and `agy` share on macOS), or `~/.gemini/antigravity-cli/antigravity-oauth-token` (the `agy` CLI's file token store), and the OAuth client in the installed `agy` or Antigravity app to renew it. While the Antigravity app runs: the port and CSRF token its language server writes to `~/.gemini/antigravity/daemon/hub_*.json` | `cloudcode-pa.googleapis.com`, `daily-cloudcode-pa.googleapis.com`, `oauth2.googleapis.com`, `www.googleapis.com`; the Antigravity app's own language server on `127.0.0.1` |
| Cursor | `cursorAuth/accessToken` in Cursor's `state.vscdb` (opened read-only), or `~/.config/cursor/auth.json` from `cursor-agent login` | `cursor.com` |
| GitHub Copilot | `~/.config/github-copilot/apps.json` / `hosts.json` (JetBrains, Vim/Neovim, Xcode plugins) or `~/.copilot/config.json` when the Copilot CLI stores its token in plain text | `api.github.com` (or your GitHub Enterprise host) |
| OpenCode | `OPENCODE_API_KEY`, or the `credential` table in OpenCode's `opencode.db` (read-only), or its older `auth.json` | `opencode.ai` |
| Kiro | kiro-cli's `data.sqlite3` (read-only) | Amazon's CodeWhisperer / Q endpoint for your region |
| Grok | `~/.grok/auth.json` (Grok CLI) | `cli-chat-proxy.grok.com` |

### Antigravity accounts

- Nothing is saved until you choose Add Account. It saves the account signed in to Antigravity, quits Antigravity, removes its sign-in (the Keychain item `gemini` / `antigravity`) and opens it on its sign-in screen. Antigravity's own Sign Out is never used, so no saved sign-in is revoked. Cancelling puts the previous sign-in back.
- Each saved account is a copy of that sign-in in a login Keychain item of this app's (service `Agent Profiles Antigravity`, one per account), written through `/usr/bin/security` like Antigravity's own. `~/Library/Application Support/AgentProfiles/Antigravity/accounts.json` lists the saved accounts' emails; it holds no tokens.
- Once an account is saved, any other account that signs in to Antigravity is saved too.
- Switching quits Antigravity, saves the sign-in it had, writes the chosen account's copy into Antigravity's Keychain item and opens Antigravity again if it was open. `agy` uses the same item, so it switches too.
- The usage of saved accounts that aren't signed in comes from Cloud Code, with each account's own sign-in; its access token is renewed in memory only.
- Forgetting an account in Settings → More Providers deletes its Keychain copy.

## Status pages

Each provider's public status page (status.claude.com, status.openai.com, and those of providers that are on) is checked every five minutes for incidents. These requests carry no credentials. Turn them off with Settings → General → Show provider status incidents.

## Notifications

Usage notifications are decided on this Mac. To fire each one once per window, the app keeps the keys of recent alerts (provider, account name, limit and reset time) in its preferences for a week.

## Usage history

- Settings → History and `agent-profiles history` draw from readings the app keeps while it runs: each account's used share of its session and weekly limits, at most one every ten minutes per account. They are the same numbers the menu already shows, keyed by Claude profile name or Codex account id, with no tokens or account details.
- They are stored in `~/Library/Application Support/AgentProfiles/usage-history.jsonl`, never sent anywhere, and dropped after 30 days. Deleting the file clears the history.

## App updates

Update checks and downloads use GitHub and its release-asset infrastructure. GitHub receives normal connection information, including your IP address. No account credentials or profile data are sent. Automatic update checks can be turned off in Settings; automatic installation is opt-in.

## Removal

Deleting a Claude profile removes its folder, which logs that account out; a Claude Code login token stays in your Keychain until you remove it. Removing a saved Codex account deletes its saved credentials and metadata; the live Codex login stays signed in. Uninstalling the app deletes neither folder above.

Preview mode (`--demo`) uses disposable sample data and disables real sign-in, client restarts, usage and status requests and app updates.
