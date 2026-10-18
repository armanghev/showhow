// swift-tools-version:5.10
import PackageDescription

// ShowHowCore holds everything that does not need AppKit: the Claude client and
// SSE parsing, the agent loop, coordinate mapping, the session log and Markdown
// exporter, the MCP protocol handling, and the whiteboard model. It builds and
// tests on Linux as well as macOS, so the logic can be verified without Xcode.
let package = Package(
    name: "ShowHowCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShowHowCore", targets: ["ShowHowCore"]),
        .executable(name: "showhow-mcp", targets: ["showhow-mcp"]),
    ],
    targets: [
        .target(name: "ShowHowCore"),
        .executableTarget(name: "showhow-mcp", dependencies: ["ShowHowCore"]),
        .testTarget(name: "ShowHowCoreTests", dependencies: ["ShowHowCore"]),
    ]
)
