// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AviaCalls",
    platforms: [.macOS("14.4")],
    dependencies: [.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")],
    targets: [
        .target(name: "AviaCallsCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "AviaCalls", dependencies: ["AviaCallsCore", .product(name: "WhisperKit", package: "WhisperKit")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AviaCallsCoreTests", dependencies: ["AviaCallsCore"],
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
