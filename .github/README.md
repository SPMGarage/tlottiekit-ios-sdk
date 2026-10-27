# TLottieKit

Swift Package for [tlottie](https://github.com/dkaraush/tlottie), the Rust Lottie renderer that Telegram uses for stickers and animated emoji. Plays Telegram `.tgs` stickers and Lottie JSON on iOS and macOS, from SwiftUI, UIKit or AppKit.

- **Fast CPU renderer.** SIMD on ARM NEON and x86. A 512×512 Telegram sticker renders in about 0.3 ms per frame on Apple Silicon (see [Performance](#performance)).
- **`.tgs` and Lottie JSON.** gzip is detected and inflated for you, with a size cap against gzip bombs.
- **SwiftUI, UIKit and AppKit players.** Rendering happens off the main thread, and playback pauses while the view is off screen.
- **Low-level API.** Render any frame into your own buffer (BGRA or RGBA, premultiplied) or into a `CGImage`.
- **Telegram features.** Color replacement, per-layer recoloring and emoji skin tones (Fitzpatrick modifiers).
- **Prebuilt binary.** A 2.5 MB XCFramework that exports only `tlottie_*` symbols, so it does not clash with other Rust libraries in your app.

This repository is a fork of [dkaraush/tlottie](https://github.com/dkaraush/tlottie). The Rust sources are upstream's and are unchanged. Everything Apple-specific lives in `apple/`, plus `Package.swift`.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/SPMGarage/tlottiekit-ios-sdk.git", from: "0.1.0"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "TLottieKit", package: "tlottiekit-ios-sdk"),
    ]),
]
```

In Xcode, use File ▸ Add Package Dependencies… with the URL `https://github.com/SPMGarage/tlottiekit-ios-sdk.git`.

Requirements: iOS 13+ or macOS 11+, Xcode 16+ (Swift 6 tools).

## Usage

### SwiftUI

```swift
import SwiftUI
import TLottieKit

struct StickerView: View {
    let animation = try? TLottieAnimation(named: "AnimatedSticker") // AnimatedSticker.tgs in the app bundle

    var body: some View {
        TLottiePlayer(animation, loopMode: .loop)
            .frame(width: 160, height: 160)
    }
}
```

`TLottiePlayer(_:loopMode:isPlaying:speed:onFinish:)` restarts a `.playOnce` animation only when `isPlaying` changes from `false` to `true`.

### UIKit / AppKit

```swift
let view = TLottieView()
view.animation = try TLottieAnimation(contentsOf: url) // .tgs or .json
view.loopMode = .playOnce
view.onFinish = { print("done") }
view.play()
```

`TLottieView` is a `UIView` on iOS and an `NSView` on macOS. Frames are rendered at the view's pixel size and drawn aspect-fit. It has `play()`, `pause()`, `stop()`, `seek(toFrame:)`, `speed` and `maximumRenderDimension`.

### Rendering frames yourself

```swift
let animation = try TLottieAnimation(data: tgsData)

// Into a CGImage:
let image = try animation.makeImage(frame: 12, width: 256, height: 256)

// Into your own buffer (a CVPixelBuffer, a Metal texture upload, a frame cache…):
try animation.render(frame: 12, into: buffer, width: 256, height: 256, bytesPerRow: bytesPerRow)
```

The default pixel format is `.bgra`, which is premultiplied `[B, G, R, A]`. That matches `CGBitmapInfo.byteOrder32Little | premultipliedFirst`, `kCVPixelFormatType_32BGRA` and `.bgra8Unorm`. Pass `Options(pixelFormat: .rgba)` for `[R, G, B, A]`.

### Options

```swift
let options = TLottieAnimation.Options(
    fitzModifier: .type3,                          // emoji skin tone
    colorReplacements: [0xFF0000: 0x0A9BF5],       // 0xRRGGBB → 0xRRGGBB
    layerColorReplacements: ["eye": 0xFF000000],   // layer-name prefix → 0xAARRGGBB
    pixelFormat: .bgra,
    maxDecompressedSize: 8 * 1024 * 1024           // .tgs inflate limit
)
let animation = try TLottieAnimation(data: data, options: options)
```

### Threading

`TLottieAnimation` is `Sendable`. One instance may be used from any thread, but its renders run one at a time, because a tlottie instance is single-threaded. To animate many stickers in parallel, as in a grid, give each view its own instance.

## Performance

Measured with this package on 2026-10-27 with the Rust core built in release mode:

| Animation                                      | Where                               | Frame time               |
| ---------------------------------------------- | ----------------------------------- | ------------------------ |
| Telegram sticker, 512×512 render, 90 frames    | macOS, Apple Silicon (`swift test`) | 0.26 ms/frame            |
| same                                           | iOS 27 Simulator on the same Mac    | 0.33 ms/frame            |
| 13 stickers playing at 60 fps in the demo grid | iOS Simulator                       | ~26–29% of one host core |

Simulator numbers come from the host CPU, not a phone. Measure on a device with Instruments before you rely on them.

The upstream author benchmarks tlottie against rlottie (which Telegram used before) and ThorVG across 17k+ Telegram animations: [benchmarks](https://dkaraush.github.io/tlottie/).

Rendering is CPU rasterization. The cost scales with pixel count, so render at the size you display, and cache frames if you show the same sticker many times.

## Demo app

`apple/Examples/TLottieDemo` holds a SwiftUI app for iOS and macOS. It has a player, speed and loop controls, a 12-player grid and a file importer for `.tgs` and `.json` files.

```sh
./apple/build-xcframework.sh          # once, builds the local XCFramework
cd apple/Examples/TLottieDemo
xcodegen generate && open TLottieDemo.xcodeproj
```

On iOS, `.tgs` files copied into the app's Documents folder (Files app, Finder) show up in the list.

## Limitations

- **No dotLottie.** `.lottie` ZIP containers are not supported yet. Unzip one and pass the JSON inside.
- **Static compositions report one frame.** tlottie reports `frameCount == 1` for a composition it can prove static.
- **Bugs crash instead of failing.** The Rust core is built with `panic=abort`, so a bug inside tlottie crashes the app. A failing render does not crash: malformed input throws `TLottieError`, because upstream treats Lottie JSON as untrusted input.

## Building the binary

The XCFramework is built from this repository's Rust sources:

```sh
./apple/build-xcframework.sh   # → apple/Artifacts/CTLottie.xcframework (+ .zip and its checksum)
swift test                     # macOS
xcodebuild test -scheme TLottieKit -destination 'platform=iOS Simulator,name=iPhone 17'
```

The script needs `rustup`, and it adds any missing iOS and macOS targets. It links each Rust static library into one object that exports only `tlottie_*`. It then combines the slices for iOS (arm64), the Simulator (arm64 and x86_64) and macOS (arm64 and x86_64).

When `apple/Artifacts/CTLottie.xcframework` exists, `Package.swift` uses it instead of the released zip, so you can work on the package without publishing anything.

To render your own sticker in the tests and get a contact sheet:

```sh
TLOTTIEKIT_STICKER=~/Downloads/sticker.tgs TLOTTIEKIT_OUTPUT=/tmp/out swift test --filter ExternalSticker
```

### Releasing

```sh
apple/release.sh 0.2.0
```

The script does the following:

1. Builds the zip.
2. Writes its URL and checksum into `Package.swift`.
3. Commits, tags and pushes.
4. Uploads the zip to GitHub Releases.

### Syncing with upstream

```sh
git fetch upstream --no-tags
git merge upstream/main
```

`--no-tags` keeps upstream's `v*` tags out of this fork. SwiftPM would treat them as versions of TLottieKit.

## License

MIT, like the code it wraps:

- tlottie © dkaraush. See [LICENSE](../LICENSE).
- The TLottieKit Swift layer and build scripts © SPMGarage contributors, MIT.

The XCFramework ships with tlottie's LICENSE file.
