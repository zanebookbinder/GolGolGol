// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoalKit",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v15)],
    products: [
        .library(name: "GoalKit", targets: ["GoalKit"]),
    ],
    targets: [
        .target(name: "GoalKit"),
        .testTarget(name: "GoalKitTests", dependencies: ["GoalKit"]),
    ]
)
