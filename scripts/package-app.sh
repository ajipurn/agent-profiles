#!/bin/zsh
# Assemble "dist/Agent Profiles.app" from a SwiftPM build: executable, the
# agent-profiles command in Contents/Helpers, Info.plist, icons and the embedded
# Sparkle framework, signed inside-out (ad-hoc unless CODE_SIGN_IDENTITY is set).
#
# Usage: scripts/package-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/swift-env.sh
CONFIGURATION="${1:-debug}"
[[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || { echo "Use debug or release" >&2; exit 1; }
python3 scripts/release_metadata.py check

# CI can supply both architectures; local builds default to the host architecture.
ARCH_ARGS=()
for arch in ${=BUILD_ARCHS:-}; do
  [[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "Unsupported architecture: $arch" >&2; exit 1; }
  ARCH_ARGS+=(--arch "$arch")
done
swift build "${SWIFT_FLAGS[@]}" -c "$CONFIGURATION" --product AgentProfiles "${ARCH_ARGS[@]}"
swift build "${SWIFT_FLAGS[@]}" -c "$CONFIGURATION" --product agent-profiles "${ARCH_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" -c "$CONFIGURATION" --show-bin-path "${ARCH_ARGS[@]}")"
APP_DIR="$ROOT/dist/Agent Profiles.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
HELPERS_DIR="$APP_DIR/Contents/Helpers"
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "Sparkle framework missing; run swift package resolve" >&2; exit 1; }

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$HELPERS_DIR"
cp "$BIN_DIR/AgentProfiles" "$MACOS_DIR/AgentProfiles"
chmod +x "$MACOS_DIR/AgentProfiles"
cp "$BIN_DIR/agent-profiles" "$HELPERS_DIR/agent-profiles"
chmod +x "$HELPERS_DIR/agent-profiles"
cp Support/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$RESOURCES_DIR/"
ditto "$SPARKLE" "$FRAMEWORKS_DIR/Sparkle.framework"
cp THIRD_PARTY_NOTICES.md "$RESOURCES_DIR/"
cp LICENSE "$RESOURCES_DIR/LICENSE.txt"

IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != - ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
# Sign nested executables from the inside out; preserve framework symlinks.
SPARKLE_VERSION="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
for component in "$SPARKLE_VERSION"/XPCServices/*.xpc(N) "$SPARKLE_VERSION/Autoupdate" "$SPARKLE_VERSION/Updater.app"; do
  [[ -e "$component" ]] && codesign "${SIGN_ARGS[@]}" "$component"
done
codesign "${SIGN_ARGS[@]}" "$FRAMEWORKS_DIR/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$HELPERS_DIR/agent-profiles"
codesign "${SIGN_ARGS[@]}" --entitlements Support/AgentProfiles.entitlements "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
if [[ -n "${BUILD_ARCHS:-}" ]]; then
  for arch in ${=BUILD_ARCHS}; do
    lipo "$MACOS_DIR/AgentProfiles" -verify_arch "$arch"
    lipo "$HELPERS_DIR/agent-profiles" -verify_arch "$arch"
  done
fi
echo "Built $APP_DIR"
