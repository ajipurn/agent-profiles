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
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
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
        // Imported from claude-profiles, which predates Swift 6. Stays in
        // Swift 5 mode until it passes strict concurrency checking.
        .target(
            name: "ClaudeProfilesCore",
            dependencies: ["CZstd"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Imported from codex-profiles (Swift 6, strict concurrency).
        .target(name: "CodexProfilesCore"),
        .target(
            name: "CodexProfilesUI",
            dependencies: ["CodexProfilesCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        // The app shell: status item, popover, windows. Hosts the Claude
        // screens directly and the Codex screens from CodexProfilesUI.
        .executableTarget(
            name: "AgentProfiles",
            dependencies: ["ClaudeProfilesCore", "CodexProfilesCore", "CodexProfilesUI"],
            swiftSettings: [.swiftLanguageMode(.v5)],
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
        // Claude core tests (Swift Testing — runs on Command Line Tools too).
        .testTarget(
            name: "ClaudeProfilesCoreTests",
            dependencies: ["ClaudeProfilesCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
