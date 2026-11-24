// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Notch"),
        // Command-line companion: `notchctl say | run | claude` (see README).
        .executableTarget(name: "notchctl", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
