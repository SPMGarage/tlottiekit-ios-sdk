// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Release builds of CTLottie are published as a zip on GitHub Releases.
// apple/release.sh rewrites these two lines for every release.
let releaseURL = "https://github.com/SPMGarage/tlottiekit-ios-sdk/releases/download/0.2.0/CTLottie.xcframework.zip"
let releaseChecksum = "539888dd8d6b803556d84ad14bfb1bebdb21ba97edfea8505600dd1fc9920371"

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
        .library(name: "TLottieKit", targets: ["TLottieKit"]),
        // GIF and MP4 loops (Telegram-style "GIFs"), played by AVFoundation.
        .library(name: "TLottieKitMedia", targets: ["TLottieKitMedia"])
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
        ),
        .target(
            name: "TLottieKitMedia",
            dependencies: ["TLottieKit"],
            path: "apple/Sources/TLottieKitMedia"
        ),
        .testTarget(
            name: "TLottieKitMediaTests",
            dependencies: ["TLottieKitMedia"],
            path: "apple/Tests/TLottieKitMediaTests",
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
