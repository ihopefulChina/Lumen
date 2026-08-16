// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lumen-mcp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "lumen-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
