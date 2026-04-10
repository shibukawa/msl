// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "msl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "mslCore", targets: ["mslCore"]),
        .executable(name: "msl", targets: ["msl"]),
        .executable(name: "MSLDesktop", targets: ["MSLDesktop"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "mslCore",
            path: "Sources/mslCore"
        ),
        .executableTarget(
            name: "msl",
            dependencies: [
                "mslCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/msl"
        ),
        .executableTarget(
            name: "MSLDesktop",
            dependencies: [
                "mslCore"
            ],
            path: "Sources/MSLDesktop"
        ),
        .testTarget(
            name: "mslTests",
            dependencies: ["mslCore"],
            path: "Tests/mslTests"
        )
    ]
)
