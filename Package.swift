// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AIUsage", targets: ["AIUsage"])],
    targets: [
        .systemLibrary(name: "CSQLite3"),
        .executableTarget(name: "AIUsage", dependencies: ["CSQLite3"], resources: [.copy("Resources/ClaudePaneMarketplace")]),
        .testTarget(name: "AIUsageTests", dependencies: ["AIUsage", "CSQLite3"])
    ]
)
