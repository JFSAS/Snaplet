// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Snaplet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Snaplet", targets: ["Snaplet"])],
    targets: [
        .executableTarget(name: "Snaplet"),
        .testTarget(name: "SnapletTests", dependencies: ["Snaplet"])
    ]
)
