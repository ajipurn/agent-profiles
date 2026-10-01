// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentProfiles",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AgentProfiles", targets: ["AgentProfiles"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
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
            dependencies: ["CZstd"]
        ),
        // Imported from codex-profiles.
        .target(name: "CodexProfilesCore"),
        // Estimated spend from local Claude Code and Codex logs, priced with
        // a generated LiteLLM snapshot (scripts/update-pricing.py).
        .target(name: "UsageCostCore"),
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
        // Codex regression checks: a plain executable, so they run without XCTest.
        .executableTarget(
            name: "CodexProfilesCheck",
            dependencies: ["CodexProfilesCore"],
            path: "Tests/CodexProfilesCheck"
        ),
        .testTarget(
            name: "UsageCostCoreTests",
            dependencies: ["UsageCostCore"]
        ),
        // Claude core tests (Swift Testing — runs on Command Line Tools too).
        .testTarget(
            name: "ClaudeProfilesCoreTests",
            dependencies: ["ClaudeProfilesCore"]
        ),
    ]
)
