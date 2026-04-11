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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", "2.56.0"..<"2.57.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "2.5.0"..<"2.6.0"),
        .package(url: "https://github.com/apple/swift-collections.git", "1.0.0"..<"1.1.0"),
        .package(url: "https://github.com/apple/swift-system.git", "1.2.0"..<"1.3.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", "0.9.0"..<"0.10.0")
    ],
    targets: [
        .target(
            name: "mslCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "SystemPackage", package: "swift-system")
            ],
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
            dependencies: ["mslCore"],
            path: "Sources/MSLDesktop"
        ),
        .testTarget(
            name: "mslTests",
            dependencies: ["mslCore"],
            path: "Tests/mslTests"
        )
    ]
)
