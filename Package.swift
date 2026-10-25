// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RMountCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RMountCore", targets: ["RMountCore"]),
    ],
    targets: [
        .target(
            name: "RMountCore",
            path: "Sources/RMountCore",
            linkerSettings: [
                .linkedFramework("NetFS"),
            ]
        ),
        .testTarget(
            name: "RMountCoreTests",
            dependencies: ["RMountCore"],
            path: "Tests/RMountCoreTests"
        ),
    ]
)
