// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "IronPet",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/adam-fowler/jmespath.swift", exact: "1.0.3"),
        .package(url: "https://github.com/zqqf16/QuickJS-Swift.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .executableTarget(name: "IronPet", dependencies: [.product(name: "JMESPath", package: "jmespath.swift"), .product(name: "QuickJS", package: "QuickJS-Swift"), .product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/IronPet"),
        .testTarget(name: "IronPetTests", dependencies: ["IronPet"], path: "Tests/IronPetTests", resources: [.copy("Fixtures")]),
    ]
)
