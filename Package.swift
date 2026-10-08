// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Voicedic",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Voicedic",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
    ]
)
