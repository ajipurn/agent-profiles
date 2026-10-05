// swift-tools-version: 6.0

import PackageDescription

// The cores build everywhere (Linux CI today, Windows next); the app shell,
// its AppKit/SwiftUI UI and Sparkle only exist on macOS.
var products: [Product] = []
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    // Paths, links, file modes and locks that differ per OS — the one place
    // the cores below spell out a platform.
    .target(name: "PlatformSupport"),
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
    // The `agent-profiles` command: status, usage, cost and switching from a
    // terminal. Its logic lives in AgentCLI, where the tests drive it.
    .target(
        name: "AgentCLI",
        dependencies: ["ClaudeProfilesCore", "CodexProfilesCore", "UsageCostCore"]
    ),
    .executableTarget(name: "AgentProfilesCLI", dependencies: ["AgentCLI"]),
    .testTarget(
        name: "AgentCLITests",
        dependencies: ["AgentCLI", "ClaudeProfilesCore", "CodexProfilesCore", "PlatformSupport"]
    ),
]
products += [
    .executable(name: "agent-profiles", targets: ["AgentProfilesCLI"]),
]

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
