// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DiskEjectorApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DiskEjectorApp",
            path: "Sources",
            sources: ["DiskEjectorApp", "Models", "Services", "Views"]
        ),
        .testTarget(
            name: "DiskEjectorAppTests",
            dependencies: ["DiskEjectorApp"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
