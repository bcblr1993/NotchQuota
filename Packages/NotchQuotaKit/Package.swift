// swift-tools-version: 5.9
import PackageDescription

// No external dependencies: a widget extension is killed above roughly 30 MB,
// so the shared layer stays on Foundation and CryptoKit only.
let package = Package(
    name: "NotchQuotaKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "NotchQuotaKit", targets: ["NotchQuotaKit"])],
    targets: [
        .target(name: "NotchQuotaKit"),
        .testTarget(name: "NotchQuotaKitTests", dependencies: ["NotchQuotaKit"])
    ]
)
