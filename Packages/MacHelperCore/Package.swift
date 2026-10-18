// swift-tools-version:5.10
import PackageDescription

// MacHelperCore holds everything that does not need AppKit: the Claude client and
// SSE parsing, the agent loop, coordinate mapping, the session log and Markdown
// exporter, the MCP protocol handling, and the whiteboard model. It builds and
// tests on Linux as well as macOS, so the logic can be verified without Xcode.
let package = Package(
    name: "MacHelperCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacHelperCore", targets: ["MacHelperCore"]),
        .executable(name: "machelper-mcp", targets: ["machelper-mcp"]),
    ],
    targets: [
        .target(name: "MacHelperCore"),
        .executableTarget(name: "machelper-mcp", dependencies: ["MacHelperCore"]),
        .testTarget(name: "MacHelperCoreTests", dependencies: ["MacHelperCore"]),
    ]
)
