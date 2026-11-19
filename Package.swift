// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Greenroom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Greenroom", path: "Sources/Greenroom"),
    ]
)
