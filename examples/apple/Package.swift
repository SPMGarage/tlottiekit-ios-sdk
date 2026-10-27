// swift-tools-version: 6.0
import PackageDescription

// Run ./build.sh first: it builds Artifacts/CTLottie.xcframework from the
// Rust sources of this repository.
let package = Package(
    name: "TLottieKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v11)
    ],
    products: [
        .library(name: "TLottieKit", targets: ["TLottieKit"])
    ],
    targets: [
        .binaryTarget(name: "CTLottie", path: "Artifacts/CTLottie.xcframework"),
        .target(
            name: "TLottieKit",
            dependencies: ["CTLottie"],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "TLottieKitTests",
            dependencies: ["TLottieKit"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
