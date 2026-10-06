// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalLedgerCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "LocalLedgerCore", targets: ["LocalLedgerCore"]),
    ],
    targets: [
        .target(name: "LocalLedgerCore"),
        .testTarget(name: "LocalLedgerCoreTests", dependencies: ["LocalLedgerCore"]),
    ]
)
