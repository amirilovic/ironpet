// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "IronPet",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/adam-fowler/jmespath.swift", exact: "1.0.3"),
        .package(path: "Vendor/QuickJS-Swift"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
        // Pinned to releases whose manifests need Swift 6.1 or older, because CI builds with 6.1 and later ones declare tools 6.2.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.16.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", exact: "2.6.0"),
        // Hummingbird's own dependencies resolve to their newest releases, which need Swift 6.2. Pinning them here keeps
        // the build on the Swift 6.1 that CI uses. None is imported by ironpet itself. Raise them together with CI's toolchain.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.9.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.1"),
        .package(url: "https://github.com/apple/swift-metrics.git", exact: "2.11.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", exact: "1.5.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.0.4"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.30.3"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.10.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", exact: "1.3.0"),
    ],
    targets: [
        .target(name: "IronPetObjC", path: "Sources/IronPetObjC"),
        .executableTarget(name: "IronPet", dependencies: ["IronPetObjC", .product(name: "JMESPath", package: "jmespath.swift"), .product(name: "QuickJS", package: "QuickJS-Swift"), .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "Hummingbird", package: "hummingbird"), .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket")], path: "Sources/IronPet"),
        .testTarget(name: "IronPetTests", dependencies: ["IronPet"], path: "Tests/IronPetTests", resources: [.copy("Fixtures")]),
    ]
)
