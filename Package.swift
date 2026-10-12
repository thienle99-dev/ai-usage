// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AIUsage", targets: ["AIUsage"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite3"),
        .executableTarget(
            name: "AIUsage",
            dependencies: ["CSQLite3", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources/ClaudePaneMarketplace"), .process("Resources/Localization")]
        ),
        .testTarget(name: "AIUsageTests", dependencies: ["AIUsage", "CSQLite3"])
    ]
)
