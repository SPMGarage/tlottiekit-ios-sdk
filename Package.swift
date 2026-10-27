// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Release builds of CTLottie are published as a zip on GitHub Releases.
// apple/release.sh rewrites these two lines for every release.
let releaseURL = "https://github.com/SPMGarage/tlottiekit-ios-sdk/releases/download/0.1.0/CTLottie.xcframework.zip"
let releaseChecksum = "701024dd5225b6f2331006138b0837f90547c8c2546b71b9c30c01efec31a14b"

// After `apple/build-xcframework.sh` the local build is used instead, so the
// package can be developed and tested without a release.
let localXCFramework = "apple/Artifacts/CTLottie.xcframework"
let useLocalBinary = releaseURL.isEmpty
    || FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + localXCFramework)

let ctlottie: Target = useLocalBinary
    ? .binaryTarget(name: "CTLottie", path: localXCFramework)
    : .binaryTarget(name: "CTLottie", url: releaseURL, checksum: releaseChecksum)

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
        ctlottie,
        .target(
            name: "TLottieKit",
            dependencies: ["CTLottie"],
            path: "apple/Sources/TLottieKit",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "TLottieKitTests",
            dependencies: ["TLottieKit"],
            path: "apple/Tests/TLottieKitTests",
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
