// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchQuota",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NotchQuota", targets: ["NotchQuota"])],
    targets: [
        .executableTarget(name: "NotchQuota", resources: [.process("Resources")]),
        .testTarget(name: "NotchQuotaTests", dependencies: ["NotchQuota"])
    ]
)
