// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchBar",
            path: "Sources/NotchBar"
        ),
        .executableTarget(
            name: "notchbar-hook",
            path: "Sources/notchbar-hook"
        ),
        .testTarget(name: "NotchBarTests", dependencies: ["NotchBar"], path: "Tests/NotchBarTests"),
        .testTarget(name: "HookTests", dependencies: ["notchbar-hook"], path: "Tests/HookTests"),
    ],
    swiftLanguageModes: [.v5]
)
