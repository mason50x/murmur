// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7")
        // Sparkle isn't a package dependency: scripts/sparkle.sh downloads a pinned, checksummed
        // release, scripts/package.sh embeds it, and Updater.swift loads it after verifying it.
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Murmur",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["Murmur"],
            path: "Tests/MurmurTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
