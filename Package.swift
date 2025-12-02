// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VM",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "vm",
            targets: ["VM"]
        ),
        .library(
            name: "VMCore",
            targets: ["VMCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "VMCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "VM",
            dependencies: [
                "VMCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: ["VM.entitlements"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "VMTests",
            dependencies: ["VMCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .plugin(
            name: "Sign",
            capability: .command(
                intent: .custom(
                    verb: "sign",
                    description: "Sign program with virtualization entitlement"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Sign the built executable")
                ]
            )
        ),
    ]
)
