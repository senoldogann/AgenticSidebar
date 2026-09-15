// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgenticSidebar",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "AgenticSidebar",
            targets: ["AgenticSidebar"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AgenticSidebar"
        ),
        .testTarget(
            name: "AgenticSidebarTests",
            dependencies: ["AgenticSidebar"]
        )
    ]
)
