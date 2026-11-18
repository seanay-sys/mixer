// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Mixer",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "Mixer",
            path: "Sources/Mixer",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ]
)
