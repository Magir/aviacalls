// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AviaCalls",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "AviaCallsCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "AviaCalls", dependencies: ["AviaCallsCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AviaCallsCoreTests", dependencies: ["AviaCallsCore"],
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
