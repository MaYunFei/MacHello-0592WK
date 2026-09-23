// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacHello-0592WK",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MacHello",
            targets: ["MacHello"]
        ),
        .library(
            name: "MacHelloCore",
            targets: ["MacHelloCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MacHelloCore",
            dependencies: [],
            path: "Sources/MacHelloCore"
        ),
        .executableTarget(
            name: "MacHello",
            dependencies: ["MacHelloCore"],
            path: "Sources/MacHello"
        ),
        .testTarget(
            name: "MacHelloTests",
            dependencies: ["MacHelloCore"],
            path: "Tests/MacHelloTests"
        )
    ]
)
