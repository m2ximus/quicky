// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quicky",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "QuickyCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Quicky", dependencies: ["QuickyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "QuickyCoreTests", dependencies: ["QuickyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
