// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IINACastHelper",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        // Web framework for REST API
        .package(url: "https://github.com/vapor/vapor", from: "4.89.0"),

        // Argument parsing for CLI
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),

        // Protobuf for CASTV2 protocol
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.25.0"),

        // Async networking
        .package(url: "https://github.com/apple/swift-nio", from: "2.62.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.25.0"),
    ],
    targets: [
        .executableTarget(
            name: "IINACastHelper",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/IINACastHelper"
        ),
    ]
)
