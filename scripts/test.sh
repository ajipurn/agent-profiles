#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/swift-env.sh

# Codex core: plain executable checks.
swift build "${SWIFT_FLAGS[@]}" --product CodexProfilesCheck
TEST_BINARY="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/CodexProfilesCheck"
# Stamp the completed test executable explicitly on both Xcode and CLT toolchains.
codesign --force --sign - "$TEST_BINARY"
codesign --verify --strict "$TEST_BINARY"
"$TEST_BINARY"

# Claude core: Swift Testing.
swift test "${SWIFT_FLAGS[@]}" "${TEST_FLAGS[@]}"
