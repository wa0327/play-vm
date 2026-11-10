// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vz",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "vz", path: "Sources/vz")
    ]
)
