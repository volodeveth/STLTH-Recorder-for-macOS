// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RecorderCore",
    platforms: [.macOS("14.4")],
    products: [.library(name: "RecorderCore", targets: ["RecorderCore"])],
    targets: [
        .target(name: "RecorderCore"),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
    ]
)
