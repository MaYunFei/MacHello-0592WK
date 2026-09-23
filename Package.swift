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
        .executable(
            name: "MacHelloPresence",
            targets: ["MacHelloPresence"]
        ),
        .executable(
            name: "MacHelloEnroll",
            targets: ["MacHelloEnroll"]
        ),
        .executable(
            name: "MacHelloAuth",
            targets: ["MacHelloAuth"]
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
                .linkedFramework("CoreVideo"),
                .linkedFramework("Vision"),
                .linkedFramework("UserNotifications")
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
        .executableTarget(
            name: "MacHelloPresence",
            dependencies: ["MacHelloCore"],
            path: "Sources/MacHelloPresence"
        ),
        .executableTarget(
            name: "MacHelloEnroll",
            dependencies: ["MacHelloCore"],
            path: "Sources/MacHelloEnroll"
        ),
        .executableTarget(
            name: "MacHelloAuth",
            dependencies: ["MacHelloCore"],
            path: "Sources/MacHelloAuth"
        ),
        .testTarget(
            name: "MacHelloTests",
            dependencies: ["MacHelloCore"],
            path: "Tests/MacHelloTests"
        )
    ]
)
