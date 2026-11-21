// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Greenroom",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates. Pinned exactly: scripts/bundle.sh signs its nested programs, and the release workflow runs its
        // generate_appcast from the same artifact.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Greenroom",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Greenroom",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
