// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftIdempotencySwiftNIOSpike",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SwiftIdempotencySwiftNIOSpike",
            targets: ["SwiftIdempotencySwiftNIOSpike"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(path: "../SwiftIdempotency"),
    ],
    targets: [
        .target(
            name: "SwiftIdempotencySwiftNIOSpike",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "SwiftIdempotency", package: "SwiftIdempotency"),
            ]
        ),
        .testTarget(
            name: "SwiftIdempotencySwiftNIOSpikeTests",
            dependencies: [
                "SwiftIdempotencySwiftNIOSpike",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "SwiftIdempotency", package: "SwiftIdempotency"),
                .product(name: "SwiftIdempotencyTestSupport", package: "SwiftIdempotency"),
            ]
        ),
    ]
)
