// swift-tools-version:5.9
// パズルルートの共通ロジック（盤面・認識・消去ルール・探索・通信データ）。
// Apple 専用フレームワークに依存しないので、macOS 上の `swift test` でそのまま検証できる。
import PackageDescription

let package = Package(
    name: "PuzzleCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "PuzzleCore", targets: ["PuzzleCore"]),
    ],
    targets: [
        .target(name: "PuzzleCore"),
        .testTarget(name: "PuzzleCoreTests", dependencies: ["PuzzleCore"]),
    ]
)
