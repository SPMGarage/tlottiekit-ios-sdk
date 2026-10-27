# TLottieKit

Swift Package for [tlottie](https://github.com/dkaraush/tlottie), the Rust Lottie renderer that Telegram uses for stickers and animated emoji. Plays Telegram `.tgs` stickers, Lottie JSON and dotLottie `.lottie` files on iOS and macOS, from SwiftUI, UIKit or AppKit.

- **Fast CPU renderer.** SIMD on ARM NEON and x86. A 512×512 Telegram sticker renders in about 0.3 ms per frame on Apple Silicon (see [Performance](#performance)).
- **`.tgs`, Lottie JSON and `.lottie`.** gzip and ZIP are detected and inflated for you, with a size cap against decompression bombs.
- **SwiftUI, UIKit and AppKit players.** Rendering happens off the main thread, and playback pauses while the view is off screen.
- **Low-level API.** Render any frame into your own buffer (BGRA or RGBA, premultiplied) or into a `CGImage`.
- **Telegram features.** Color replacement, per-layer recoloring and emoji skin tones (Fitzpatrick modifiers).
- **Prebuilt binary.** A 2.5 MB XCFramework that exports only `tlottie_*` symbols, so it does not clash with other Rust libraries in your app.

This repository is a fork of [dkaraush/tlottie](https://github.com/dkaraush/tlottie). The Rust sources are upstream's and are unchanged. Everything Apple-specific lives in `apple/`, plus `Package.swift`.

> **AI coding agents:** read [`AGENTS.md`](../AGENTS.md). It has the complete API, the behaviour contracts, the build invariants and the do/don't rules.

## Why this package exists

Upstream tlottie is a Rust crate with a C API. It ships no `Package.swift`, no XCFramework and no Swift API. Its only samples are `examples/android` (NDK + JNI) and `examples/web` (WASM).

Telegram iOS builds tlottie from source with Bazel. It is not Bazel-specific code: any Xcode project can use it. Without this package, though, every project has to do the following by hand:

1. Install Rust.
2. Build a separate static library for the device and for the simulator.
3. Link it and set up a bridging header.
4. Write its own `.tgs` loading, image conversion and playback.

TLottieKit does all of that once. Add the URL and write `import TLottieKit`.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/SPMGarage/tlottiekit-ios-sdk.git", from: "0.2.0"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "TLottieKit", package: "tlottiekit-ios-sdk"),
        .product(name: "TLottieKitMedia", package: "tlottiekit-ios-sdk"), // optional: GIF / MP4
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
view.animation = try TLottieAnimation(contentsOf: url) // .tgs, .json or .lottie
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
    maxDecompressedSize: 8 * 1024 * 1024           // .tgs / .lottie inflate limit
)
let animation = try TLottieAnimation(data: data, options: options)
```

### Threading

`TLottieAnimation` is `Sendable`. One instance may be used from any thread, but its renders run one at a time, because a tlottie instance is single-threaded. To animate many stickers in parallel, as in a grid, give each view its own instance.

### GIF and MP4 (`TLottieKitMedia`)

Telegram sends "GIFs" as silent H.264 MP4 loops. The optional `TLottieKitMedia` product plays those, and real GIFs, with the same API as `TLottiePlayer` / `TLottieView`:

```swift
import TLottieKitMedia

TLottieMediaPlayer(try? TLottieMedia(contentsOf: url))   // .gif, .mp4 or .mov, detected by content
    .aspectRatio(1, contentMode: .fit)
```

- **Video** goes from `AVAssetReader` to an `AVSampleBufferDisplayLayer` and is decoded by the system (usually in hardware). Audio is never read, so the user's music keeps playing.
- **GIF** frames are decoded with ImageIO. Frame delays of 10 ms or less play as 100 ms, as in browsers. Transparency works.
- **Timing** comes from a `CMTimebase`, not a display link. Loops are seamless, and pause and speed only change the timebase rate.
- **Off screen costs nothing.** A view plays only while it is in a window. Coming back restarts from the first frame.
- **One `TLottieMedia` can back many views**, as in a grid. Each view decodes on its own.
- **Not supported:** WebM / VP9 (Telegram video stickers). H.264 has no alpha channel.

## Supported files

| File                                    | Supported                                                        |
| --------------------------------------- | ---------------------------------------------------------------- |
| Telegram `.tgs`                         | Yes. gzip is detected from the file contents, not the extension. |
| Lottie JSON `.json` (Bodymovin)         | Yes, for the features listed below.                              |
| dotLottie `.lottie`                     | Yes. Plays the initial animation, without themes or states.      |
| GIF, MP4, MOV                           | Yes, with `TLottieKitMedia` (see above). Not Lottie.             |
| WebM, APNG, WebP, SVG, Rive `.riv`      | No. These are not Lottie.                                        |

**Renders:**

- **Layers:** shape, solid, null, precomp and parenting.
- **Shapes:** path, rect, ellipse, star/polygon.
- **Paint:** fill, stroke, gradient fill and gradient stroke.
- **Modifiers:** trim path, round corners, repeater.
- **Layer effects:** masks, track mattes, time remap and time stretch.

**Skipped without an error:**

- text layers;
- image layers (embedded images);
- expressions;
- merge paths;
- layer effects.

Anything valid as a Telegram sticker renders fully.

### Where to get animations

- **Telegram stickers (`.tgs`).** Save them from Telegram Desktop or macOS, or fetch them with the Bot API (`getStickerSet` + `getFile`). Stickers belong to their authors, so get permission before you ship one in an app.
- **[LottieFiles](https://lottiefiles.com).** Both the default `.lottie` download and **Lottie JSON** work. Check each animation's license.
- **Animated icon sites** (Lordicon, IconScout, …). They export Lottie JSON; free tiers usually require attribution.
- **Your own.** Use After Effects with the Bodymovin or LottieFiles plugin; Bodymovin-TG only allows Telegram-safe features. LottieFiles Creator and Figma plugins also export Lottie.
- **Conversions.**
  - `.json` → `.tgs`: `gzip -9 -n anim.json > anim.tgs`
  - Other formats: `pip install lottie` (python-lottie).

To check a file quickly, open it in the demo app, or run:

```sh
TLOTTIEKIT_STICKER=~/Downloads/anim.json TLOTTIEKIT_OUTPUT=/tmp/out swift test --filter ExternalSticker
```

The test prints the frame time and writes a contact sheet of the frames.

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

`apple/Examples/TLottieDemo` holds a SwiftUI app for iOS and macOS. Its files are grouped by format (Lottie JSON, Telegram `.tgs`, dotLottie, GIF, MP4 / MOV), and a header shows what is playing, in which format and through which engine. It has speed and loop controls, a 12-player grid and a file importer. Pass `-select <name>` to open a sample at launch, and `-grid` to show the grid.

`TLottieDemoUITests` taps every sample like a user would and checks the header and that the player animates:

```sh
xcodebuild test -project apple/Examples/TLottieDemo/TLottieDemo.xcodeproj -scheme TLottieDemo-iOS \
    -destination 'platform=iOS Simulator,name=iPhone 17'
```

```sh
./apple/build-xcframework.sh          # once, builds the local XCFramework
cd apple/Examples/TLottieDemo
xcodegen generate && open TLottieDemo.xcodeproj
```

On iOS, files copied into the app's Documents folder (Files app, Finder) show up in the list.

## Limitations

- **No text, images or expressions.** See [Supported files](#supported-files). dotLottie themes and state machines are ignored.
- **No WebM video stickers.** `TLottieKitMedia` plays GIF, MP4 and MOV only.
- **No frame cache yet.** Each frame is rendered into a new buffer. For grids that repeat the same sticker, cache frames in your app.
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
