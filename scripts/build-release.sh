#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 scripts/release_metadata.py check --require-key
VERSION="$(python3 scripts/release_metadata.py get version)"
REPOSITORY="$(python3 scripts/release_metadata.py get repository)"
./scripts/package-app.sh release
OUT="$ROOT/dist/releases/$VERSION"
APP="$ROOT/dist/Agent Profiles.app"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
ARCHIVE="$OUT/AgentProfiles-$VERSION.zip"
mkdir -p "$OUT"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  [[ "${CODE_SIGN_IDENTITY:--}" != - ]] || { echo "Notarization requires a Developer ID identity" >&2; exit 1; }
  NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  [[ -z "${NOTARY_KEYCHAIN:-}" ]] || NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
  xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm "$ARCHIVE"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
fi

SIGN_ARGS=(--account dev.aji.AgentProfiles.release)
SIGNING_FILE=""
trap '[[ -z "$SIGNING_FILE" ]] || rm -f "$SIGNING_FILE"' EXIT
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  SIGNING_FILE="$(mktemp "${TMPDIR:-/tmp/}agent-signing.XXXXXX")"
  chmod 600 "$SIGNING_FILE"
  # Never place the private key in arguments, release artifacts, or logs.
  python3 - "$SIGNING_FILE" <<'PY'
import os,sys
from pathlib import Path
Path(sys.argv[1]).write_text(os.environ['SPARKLE_PRIVATE_KEY'].strip())
PY
  SIGN_ARGS=(--ed-key-file "$SIGNING_FILE")
fi

[[ -f "docs/releases/$VERSION.md" ]] || { echo "Missing release notes" >&2; exit 1; }
cp "docs/releases/$VERSION.md" "$OUT/AgentProfiles-$VERSION.md"
# Rebuild only this version's feed; GitHub's latest-release URL remains stable.
rm -f "$OUT/appcast.xml"
"$TOOLS/generate_appcast" "${SIGN_ARGS[@]}" \
  --maximum-deltas 0 --maximum-versions 1 --embed-release-notes \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
  --link "https://github.com/$REPOSITORY" "$OUT"
"$TOOLS/sign_update" "${SIGN_ARGS[@]}" --verify "$OUT/appcast.xml"
swift scripts/verify-update.swift "$OUT/appcast.xml" "$ARCHIVE" \
  "$(python3 scripts/release_metadata.py get sparkle_public_key)"
python3 scripts/validate_artifacts.py "$OUT"
(
  cd "$OUT"
  shasum -a 256 "AgentProfiles-$VERSION.zip" appcast.xml "AgentProfiles-$VERSION.md" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
echo "Verified release artifacts: $OUT"
