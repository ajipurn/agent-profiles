// swift-tools-version: 6.0

import PackageDescription

// The cores build everywhere (CI tests them on Windows too); the app shell,
// its AppKit/SwiftUI UI and Sparkle only exist on macOS, and the claude
// launcher only on Windows.
var products: [Product] = []
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    // Paths, links, file modes and locks that differ per OS — the one place
    // the cores below spell out a platform.
    .target(
        name: "PlatformSupport",
        linkerSettings: [
            // The registry (the user's PATH) and the broadcast that announces it.
            .linkedLibrary("advapi32", .when(platforms: [.windows])),
            .linkedLibrary("user32", .when(platforms: [.windows])),
        ]
    ),
    // Vendored zstd 1.5.7 (decompress side only, BSD) — Claude Desktop's
    // HTTP cache stores response bodies zstd-compressed and macOS ships no
    // system decoder. Assembly is skipped for portability.
    .target(
        name: "CZstd",
        exclude: ["LICENSE"],
        cSettings: [
            .headerSearchPath("lib"),
            .headerSearchPath("lib/common"),
            .define("ZSTD_DISABLE_ASM"),
        ]
    ),
    // Imported from claude-profiles.
    .target(
        name: "ClaudeProfilesCore",
        dependencies: ["CZstd", "PlatformSupport"]
    ),
    // Imported from codex-profiles.
    .target(name: "CodexProfilesCore", dependencies: ["PlatformSupport"]),
    // Estimated spend from local Claude Code and Codex logs, priced with
    // a generated LiteLLM snapshot (scripts/update-pricing.py).
    .target(name: "UsageCostCore", dependencies: ["PlatformSupport"]),
    // Codex regression checks: a plain executable, so they run without XCTest.
    .executableTarget(
        name: "CodexProfilesCheck",
        dependencies: ["CodexProfilesCore"],
        path: "Tests/CodexProfilesCheck"
    ),
    .testTarget(
        name: "PlatformSupportTests",
        dependencies: ["PlatformSupport"]
    ),
    .testTarget(
        name: "UsageCostCoreTests",
        dependencies: ["UsageCostCore"]
    ),
    // Claude core tests (Swift Testing — runs on Command Line Tools too).
    .testTarget(
        name: "ClaudeProfilesCoreTests",
        dependencies: ["ClaudeProfilesCore", "PlatformSupport"]
    ),
]

#if os(Windows)
targets += [
    // `claude.exe` and `claude-profile.exe` for Claude Code (CLI) profiles,
    // copied into _cli\bin by CLIProfileManager. Plain C on Win32, linked
    // without Swift's startup object, so the copies need no Swift runtime
    // beside them.
    .executableTarget(
        name: "ClaudeLauncher",
        linkerSettings: [
            .linkedLibrary("shell32"),
            .unsafeFlags(["-nostartfiles"]),
        ]
    ),
]
#endif

#if os(macOS)
products += [
    .executable(name: "AgentProfiles", targets: ["AgentProfiles"]),
]
dependencies += [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
]
targets += [
    // Menu card, account rows, switcher and menu bar icon shared by both
    // providers (CodexBar-style).
    .target(name: "AgentUI"),
    .target(
        name: "CodexProfilesUI",
        dependencies: ["AgentUI", "CodexProfilesCore", .product(name: "Sparkle", package: "Sparkle")]
    ),
    // The app shell: status item, menu, Settings window. Hosts the Claude
    // screens directly and the Codex ones from CodexProfilesUI.
    .executableTarget(
        name: "AgentProfiles",
        dependencies: ["AgentUI", "ClaudeProfilesCore", "CodexProfilesCore", "CodexProfilesUI", "UsageCostCore"],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SwiftUI"),
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
        ]
    ),
]
#endif

let package = Package(
    name: "AgentProfiles",
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
