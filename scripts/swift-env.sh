# Sourced by the build and test scripts (zsh). Works around problems seen
# with the macOS 27 Command Line Tools when no Xcode is installed:
#  - SwiftPM's default `swiftbuild` engine fails to start ("Unknown error
#    parsing property list"); the native build system still works. Only
#    used there: universal (multi-arch) builds need the default engine.
#  - The macOS 27 SDK turns SwiftUI's @State into a macro whose plugin ships
#    only with Xcode, so SwiftUI code has to build against a macOS 26 SDK.
#  - The native build system does not find the Command Line Tools' copy of
#    Swift Testing, so `swift test` gets its paths spelled out (TEST_FLAGS).
# An explicit SDKROOT or SWIFT_BUILD_SYSTEM always wins.
SWIFT_FLAGS=()
[[ -z "${SWIFT_BUILD_SYSTEM:-}" ]] || SWIFT_FLAGS=(--build-system "$SWIFT_BUILD_SYSTEM")
TEST_FLAGS=()
if [[ "$(xcode-select -p 2>/dev/null)" == */CommandLineTools ]]; then
  [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]] || SWIFT_FLAGS=(--build-system native)
  testing="$(xcode-select -p)/Library/Developer/Frameworks"
  TEST_FLAGS=(
    -Xswiftc -F -Xswiftc "$testing"
    -Xlinker -F -Xlinker "$testing"
    -Xlinker -rpath -Xlinker "$testing"
    -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
  )
fi
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p 2>/dev/null)" == */CommandLineTools ]]; then
  sdk_major="$(xcrun --show-sdk-version 2>/dev/null)"
  sdk_major="${sdk_major%%.*}"
  if (( ${sdk_major:-0} >= 27 )); then
    sdk26=( "$(xcode-select -p)"/SDKs/MacOSX26.*.sdk(N-/nOn) )
    if (( ${#sdk26} )); then
      export SDKROOT="${sdk26[1]}"
    else
      echo "warning: macOS ${sdk_major} SDK without Xcode may fail to build SwiftUI code; install Xcode or a macOS 26 SDK" >&2
    fi
  fi
fi
