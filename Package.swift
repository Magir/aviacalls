// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AviaCalls",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        .target(name: "AviaCallsCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "AviaCalls",
                          dependencies: ["AviaCallsCore", .product(name: "WhisperKit", package: "WhisperKit"), .product(name: "Sparkle", package: "Sparkle")],
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          // Sparkle.framework лежит внутри .app, см. Makefile
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "AviaCallsCoreTests", dependencies: ["AviaCallsCore"],
                    resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
