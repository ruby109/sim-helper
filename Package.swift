// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "sim-helper",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "sim-helper", targets: ["sim-helper"])],
    targets: [
        .target(name: "SimHelperCore"),
        .executableTarget(name: "sim-helper", dependencies: ["SimHelperCore"]),
        .testTarget(name: "SimHelperCoreTests", dependencies: ["SimHelperCore"]),
    ]
)
