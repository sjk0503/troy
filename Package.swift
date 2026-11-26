// swift-tools-version: 6.2
import PackageDescription

/// UI targets run on the main actor unless a declaration says otherwise.
let ui: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Troy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TroyCore", targets: ["TroyCore"]),
        .executable(name: "troy", targets: ["TroyCLI"]),
        .executable(name: "TroyApp", targets: ["TroyApp"]),
    ],
    targets: [
        // Storage, search and graph rules. No dependencies beyond the system SQLite.
        .target(name: "TroyCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // MCP protocol over stdio, the tools, and the text agents read.
        .target(name: "TroyMCP", dependencies: ["TroyCore"]),
        // `troy` command line tool; `troy mcp` is the MCP server.
        .executableTarget(name: "TroyCLI", dependencies: ["TroyCore", "TroyMCP"]),
        // Force-directed layout and the canvas that draws it.
        .target(name: "TroyGraph"),
        // App state, design tokens and shared views.
        .target(name: "TroyUI", dependencies: ["TroyCore"], swiftSettings: ui),
        // Main window: sidebar, record list, inspector, editor, graph screen.
        .target(name: "TroyMainUI", dependencies: ["TroyCore", "TroyUI", "TroyGraph"], swiftSettings: ui),
        // Menu bar app shell, panel and settings.
        .executableTarget(
            name: "TroyApp",
            dependencies: ["TroyCore", "TroyMCP", "TroyUI", "TroyMainUI"],
            swiftSettings: ui
        ),
        .testTarget(name: "TroyCoreTests", dependencies: ["TroyCore"]),
        .testTarget(name: "TroyMCPTests", dependencies: ["TroyCore", "TroyMCP"]),
        .testTarget(name: "TroyGraphTests", dependencies: ["TroyGraph"]),
        // No default main-actor isolation in these two: the Swift Testing macros do not expand under it.
        .testTarget(name: "TroyUITests", dependencies: ["TroyCore", "TroyUI"]),
        .testTarget(name: "TroyMainUITests", dependencies: ["TroyMainUI"]),
    ]
)
