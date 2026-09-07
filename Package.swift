// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Notchification",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Notchification", path: "Sources"),
        .testTarget(name: "NotchificationTests", dependencies: ["Notchification"], path: "Tests"),
    ]
)
