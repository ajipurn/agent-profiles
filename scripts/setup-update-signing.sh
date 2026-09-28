#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift package resolve
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
ACCOUNT="dev.aji.AgentProfiles.release"
# Dedicated keychain account; rerunning reuses the existing signing key.
"$TOOLS/generate_keys" --account "$ACCOUNT"
PUBLIC_KEY="$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)"
python3 - "$PUBLIC_KEY" <<'PY'
import base64,json,sys
from pathlib import Path
key=sys.argv[1].strip()
assert len(base64.b64decode(key,validate=True))==32, 'Invalid signing public key'
p=Path('Config/release.json'); config=json.loads(p.read_text())
if config['sparkle_public_key'] and config['sparkle_public_key'] != key:
    raise SystemExit('Existing public key differs. Do not rotate release keys accidentally.')
config['sparkle_public_key']=key
p.write_text(json.dumps(config,indent=2)+'\n')
PY
python3 scripts/release_metadata.py sync
echo "Public key saved. The private key stays in your login Keychain."
