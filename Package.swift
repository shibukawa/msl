// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "msl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "mslCore", targets: ["mslCore"]),
        .executable(name: "msl", targets: ["msl"])
    ],
    targets: [
        .target(
            name: "mslCore",
            path: "Sources/mslCore"
        ),
        .executableTarget(
            name: "msl",
            dependencies: ["mslCore"],
            path: "Sources/msl"
        ),
        .testTarget(
            name: "mslTests",
            dependencies: ["mslCore"],
            path: "Tests/mslTests"
        )
    ]
)
