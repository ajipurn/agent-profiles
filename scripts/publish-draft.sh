#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TAG="${1:?Pass a release tag}"
python3 scripts/release_metadata.py check --require-key --tag "$TAG"
VERSION="$(python3 scripts/release_metadata.py get version)"
REPOSITORY="$(python3 scripts/release_metadata.py get repository)"
OUT="$ROOT/dist/releases/$VERSION"
python3 scripts/validate_artifacts.py "$OUT" --universal
python3 scripts/check-release-history.py
(cd "$OUT" && shasum -a 256 -c SHA256SUMS)
ASSETS=("$OUT/AgentProfiles-$VERSION.zip" "$OUT/appcast.xml" "$OUT/AgentProfiles-$VERSION.md" "$OUT/SHA256SUMS")
if EXISTING="$(gh release view "$TAG" --repo "$REPOSITORY" --json isDraft --jq .isDraft 2>/dev/null)"; then
  [[ "$EXISTING" == true ]] || { echo 'Refusing to replace assets of a published release.' >&2; exit 1; }
  gh release upload "$TAG" --repo "$REPOSITORY" --clobber "${ASSETS[@]}"
else
  gh release create "$TAG" --repo "$REPOSITORY" --verify-tag --draft \
    --title "Agent Profiles $VERSION" --notes-file "docs/releases/$VERSION.md" "${ASSETS[@]}"
fi
