#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'This script is for GitHub-hosted CI only.' >&2; exit 1; }
if [[ -z "${CERTIFICATE_P12:-}" ]]; then
  if [[ -n "${NOTARY_API_KEY:-}" || -n "${SIGNING_IDENTITY:-}" ]]; then
    echo 'Apple signing is partially configured; supply all certificate secrets.' >&2
    exit 1
  fi
  echo 'Building with an ad-hoc code signature and signed Sparkle updates (not notarized).'
  exit 0
fi
[[ -n "${CERTIFICATE_PASSWORD:-}" && -n "${SIGNING_IDENTITY:-}" ]] || { echo 'Missing certificate password or signing identity.' >&2; exit 1; }
umask 077
python3 - <<'PY'
import base64,os
from pathlib import Path
Path(os.environ['RUNNER_TEMP'],'agent-signing.p12').write_bytes(base64.b64decode(os.environ['CERTIFICATE_P12'],validate=True))
PY
SIGNING_KEYCHAIN="$RUNNER_TEMP/agent-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
echo "SIGNING_KEYCHAIN=$SIGNING_KEYCHAIN" >> "$GITHUB_ENV"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security import "$RUNNER_TEMP/agent-signing.p12" -P "$CERTIFICATE_PASSWORD" -k "$SIGNING_KEYCHAIN" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
security list-keychains -d user -s "$SIGNING_KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
echo "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" >> "$GITHUB_ENV"
if [[ -n "${NOTARY_API_KEY:-}" ]]; then
  [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] || { echo 'Incomplete notarization secrets.' >&2; exit 1; }
  python3 - <<'PY'
import os
from pathlib import Path
Path(os.environ['RUNNER_TEMP'],'agent-notary.p8').write_text(os.environ['NOTARY_API_KEY'])
PY
  xcrun notarytool store-credentials agent-profiles --key "$RUNNER_TEMP/agent-notary.p8" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --keychain "$SIGNING_KEYCHAIN"
  echo 'NOTARY_KEYCHAIN_PROFILE=agent-profiles' >> "$GITHUB_ENV"
  echo "NOTARY_KEYCHAIN=$SIGNING_KEYCHAIN" >> "$GITHUB_ENV"
fi
