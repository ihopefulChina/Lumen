// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ossuno-mcp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "ossuno-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ossuno-mcpTests",
            dependencies: [
                "ossuno-mcp",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
