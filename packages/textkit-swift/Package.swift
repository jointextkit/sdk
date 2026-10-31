// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TextKit",
    // Server-side: macOS for development, Linux in production. The API key is
    // secret, so this package is never meant to ship inside an iOS app.
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "TextKit", targets: ["TextKit"]),
    ],
    dependencies: [
        // HMAC-SHA256 for webhook signatures: CryptoKit's API, on Linux too.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "TextKit",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "TextKitTests",
            dependencies: ["TextKit", .product(name: "Crypto", package: "swift-crypto")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
