// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "IronPet",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IronPetObjC", path: "Sources/IronPetObjC"),
        .executableTarget(name: "IronPet", dependencies: ["IronPetObjC"], path: "Sources/IronPet"),
        .testTarget(name: "IronPetTests", dependencies: ["IronPet"], path: "Tests/IronPetTests"),
    ]
)
