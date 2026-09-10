// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchQuota",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NotchQuota", targets: ["NotchQuota"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .executableTarget(name: "NotchQuota", dependencies: [.product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "NotchQuotaTests", dependencies: ["NotchQuota"])
    ]
)
