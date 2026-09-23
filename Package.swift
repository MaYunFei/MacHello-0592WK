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
        .executable(
            name: "MacHelloDoctor",
            targets: ["MacHelloDoctor"]
        ),
        .library(
            name: "MacHelloCore",
            targets: ["MacHelloCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CIOKitHelper",
            path: "Sources/CIOKitHelper",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "MacHelloCore",
            dependencies: ["CIOKitHelper"],
            path: "Sources/MacHelloCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo")
            ]
        ),
        .executableTarget(
            name: "MacHello",
            dependencies: ["MacHelloCore"],
            path: "Sources/MacHello"
        ),
        .executableTarget(
            name: "MacHelloDoctor",
            dependencies: ["MacHelloCore"],
            path: "Sources/MacHelloDoctor"
        ),
        .testTarget(
            name: "MacHelloTests",
            dependencies: ["MacHelloCore"],
            path: "Tests/MacHelloTests"
        )
    ]
)
