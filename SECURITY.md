# Security

Report vulnerabilities privately through [GitHub security advisories](https://github.com/ajipurn/agent-profiles/security/advisories/new). Do not post live credentials, `auth.json` files or Claude profile folders in an issue.

Only the latest stable release receives security fixes. Reports about credential handling, local file permissions, profile folder moves, update signatures and account switching are especially relevant.

Saved Codex credentials are stored locally in files with restricted permissions and are not encrypted by Agent Profiles. The app's **update-signing private key** is a separate maintainer credential kept in macOS Keychain and the GitHub Actions secret store; it is never bundled with the app.

Updates use HTTPS, signed Sparkle appcasts and Ed25519 archive verification before extraction. The public verification key is embedded in the app. Automatic installation is optional. Do not change the update-signing public key in a normal release; follow Sparkle's key-rotation guidance if a signing key is lost or compromised.

See [PRIVACY.md](PRIVACY.md) for data storage and network destinations.
