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
        
        // Chromecast protocol implementation
        .package(url: "https://github.com/mhmiles/OpenCastSwift", from: "0.5.0"),
        
        // UPNP/DLNA implementation
        .package(url: "https://github.com/katoemba/SwiftUPnP", from: "1.0.0"),
        
        // Argument parsing for CLI
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "IINACastHelper",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "OpenCastSwift", package: "OpenCastSwift"),
                .product(name: "SwiftUPnP", package: "SwiftUPnP"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/IINACastHelper"
        ),
    ]
)
