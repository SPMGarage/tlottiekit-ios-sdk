# AGENTS.md: TLottieKit

Guide for AI coding agents. It covers two jobs: **(A)** integrating TLottieKit into an app, and **(B)** changing this repository.
Every statement below was checked against the source as of TLottieKit 0.1.0 (2026-10-27). If code and this file disagree, the code wins. Fix this file in the same change.

## 0. Identity

| Key                                      | Value                                                                                           |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Repository                               | `https://github.com/SPMGarage/tlottiekit-ios-sdk` (GitHub fork of `dkaraush/tlottie`)           |
| SwiftPM product / module                 | `TLottieKit` (`import TLottieKit`)                                                              |
| Package identity in `.product(package:)` | `tlottiekit-ios-sdk`                                                                            |
| Latest release                           | `0.1.0`                                                                                         |
| Platforms                                | iOS 13+, macOS 11+ (no tvOS, watchOS, visionOS or Mac Catalyst slices)                          |
| Toolchain                                | swift-tools-version 6.0, Swift 6 language mode, Xcode 16+                                       |
| Renderer                                 | tlottie (Rust, CPU rasterizer with SIMD), shipped as the prebuilt static `CTLottie.xcframework` |
| License                                  | MIT. tlottie © dkaraush; Swift layer © SPMGarage contributors                                   |

`https://github.com/dkaraush/tlottie` is **not** a Swift package: it has no `Package.swift`. Always depend on the SPMGarage URL.

---

## A. Integrating TLottieKit into an app

### A1. Add the dependency

```swift
// Package.swift
.package(url: "https://github.com/SPMGarage/tlottiekit-ios-sdk.git", from: "0.1.0"),
// target dependency
.product(name: "TLottieKit", package: "tlottiekit-ios-sdk"),
```

In Xcode, use File ▸ Add Package Dependencies…, paste the same URL, choose "Up to Next Major 0.1.0" and add `TLottieKit` to the app target. No Rust toolchain is needed: SwiftPM downloads the binary from GitHub Releases and checks its checksum.

### A2. Supported input

| Input                                        | Supported                          | How it is handled                                                                                  |
| -------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------- |
| Telegram `.tgs`                              | yes                                | gzip, detected by the magic bytes `1f 8b` regardless of file extension, inflated in-process (zlib) |
| Lottie JSON `.json` (Bodymovin)              | yes, within the feature list below | passed to tlottie as is                                                                            |
| dotLottie `.lottie` (ZIP)                    | **no**                             | unzip it and pass `a/<name>.json` (dotLottie v2 layout)                                            |
| WebM / GIF / APNG / WebP / SVG / Rive `.riv` | **no**                             | not Lottie                                                                                         |

Lottie features that **render**:

- **Layers:** shape (`ty 4`), solid (`ty 1`), null (`ty 3`), precomp (`ty 0`).
- **Shapes:** group, path, rect, ellipse, polystar.
- **Paint:** fill, stroke, gradient fill, gradient stroke.
- **Modifiers:** trim path, round corners, repeater.
- **Layer-level:** masks, track mattes, time remap, time stretch, parenting.

Features that **do not render**:

- image layers (`ty 2`), so embedded images are not drawn;
- text layers (`ty 5`);
- expressions;
- merge paths;
- layer effects.

Unsupported layers are parsed and skipped. They do not throw.

Rule of thumb: anything valid as a Telegram sticker renders fully, because Telegram's sticker rules forbid exactly the unsupported features.

### A3. Public API (complete)

```swift
public final class TLottieAnimation: @unchecked Sendable {
    public struct Options: Sendable {
        public var fitzModifier: TLottieFitzModifier            // default .none
        public var colorReplacements: [UInt32: UInt32]           // 0xRRGGBB -> 0xRRGGBB, alpha byte ignored; default [:]
        public var layerColorReplacements: [String: UInt32]      // layer-name prefix -> straight-alpha 0xAARRGGBB; default [:]
        public var pixelFormat: TLottiePixelFormat               // default .bgra
        public var maxDecompressedSize: Int                      // .tgs inflate cap in bytes; default 8 MiB
        public init(fitzModifier:colorReplacements:layerColorReplacements:pixelFormat:maxDecompressedSize:) // all defaulted
    }
    public init(data: Data, options: Options = Options()) throws
    public convenience init(contentsOf url: URL, options: Options = Options()) throws
    public convenience init(named name: String, bundle: Bundle = .main, options: Options = Options()) throws // looks for name.tgs, then name.json
    public let size: CGSize            // composition w x h
    public let frameCount: Int         // >= 1; a composition tlottie proves static reports 1
    public let frameRate: Double       // `fr`, or 0 when missing/invalid
    public let pixelFormat: TLottiePixelFormat
    public var duration: TimeInterval  // frameCount / frameRate, 0 when frameRate == 0
    public func render(frame: Double, into buffer: UnsafeMutableRawBufferPointer,
                       width: Int, height: Int, bytesPerRow: Int) throws
    public func makeImage(frame: Double, width: Int, height: Int) throws -> CGImage
}

public enum TLottieError: Error, Equatable, Sendable {
    case invalidData, decompressionFailed, decompressedSizeLimitExceeded(limit: Int),
         resourceNotFound(name: String), invalidArgument, bufferTooSmall, renderFailed
}
public enum TLottiePixelFormat: Sendable { case bgra, rgba }   // both premultiplied alpha
public enum TLottieFitzModifier: Sendable { case none, type12, type3, type4, type5, type6 }
public enum TLottieLoopMode: Sendable, Equatable { case loop, playOnce }

@MainActor open class TLottieView: TLottiePlatformView {   // UIView on iOS, NSView on macOS
    public var animation: TLottieAnimation?    // setting it shows frame 0; does not autoplay
    public var loopMode: TLottieLoopMode       // default .loop
    public var speed: Double                   // default 1, clamped to >= 0
    public var maximumRenderDimension: Int     // default 2048 px (longest side)
    public var onFinish: (() -> Void)?         // main thread, .playOnce only
    public private(set) var isPlaying: Bool
    public var currentFrame: Int
    public func play(); public func pause(); public func stop(); public func seek(toFrame: Int)
}

public struct TLottiePlayer: UIViewRepresentable /* NSViewRepresentable on macOS */ {
    public init(_ animation: TLottieAnimation?, loopMode: TLottieLoopMode = .loop,
                isPlaying: Bool = true, speed: Double = 1, onFinish: (() -> Void)? = nil)
}
```

### A4. Behaviour contracts

- **Pixels.**
  - `.bgra` gives `[B,G,R,A]` bytes, premultiplied. That is `CGBitmapInfo.byteOrder32Little | CGImageAlphaInfo.premultipliedFirst`, `kCVPixelFormatType_32BGRA` and `MTLPixelFormat.bgra8Unorm`.
  - `.rgba` gives `[R,G,B,A]` bytes: `byteOrder32Big | premultipliedLast`.
  - Row 0 is the top of the image.
  - `makeImage` returns an sRGB `CGImage` in the instance's `pixelFormat`.
- **`render(...)`.**
  - It overwrites `width*4` bytes of every row and never touches row padding.
  - Requirements: `bytesPerRow >= width*4` and `buffer.count >= bytesPerRow*height`.
  - Width, height and frame must be valid (`> 0`, finite), otherwise it throws `.invalidArgument` or `.bufferTooSmall`.
  - Unaligned or padded buffers work, through an internal packed scratch copy.
  - `frame` may be fractional, which interpolates between frames. Valid range is `0 ..< frameCount`.
  - tlottie's hard limit is 8192 px per side.
- **Threading.**
  - `TLottieAnimation` is `Sendable`. Calls are serialized by an internal lock, because a tlottie instance is single-threaded.
  - Many animations rendering in parallel need **one instance each**. Data can be shared: parse the same `Data` several times.
- **`TLottieView`.**
  - Renders on a background serial queue at bounds × screen scale, aspect-fit. The longest side is capped by `maximumRenderDimension`.
  - Advances only while `isPlaying && window != nil && speed > 0 && frameCount > 1 && frameRate > 0`.
  - The timer is `CADisplayLink` on iOS, with `preferredFrameRateRange` = animation fps × speed (capped at 120). On macOS it is a `Timer`.
  - Off-window views cost nothing.
- **`TLottiePlayer` (SwiftUI).**
  - It calls `play()` only when `isPlaying` flips `false → true` or the animation instance changes. A finished `.playOnce` is therefore not restarted by unrelated SwiftUI updates.
  - It has no intrinsic size. Give it a `.frame` or `.aspectRatio`.
- **Errors.**
  - Malformed JSON, a corrupt or truncated gzip, or an oversized inflate throws. None of them crash.
  - A bug _inside_ tlottie aborts the process: the Rust core is built with `panic=abort`.

### A5. Recipes (all compile against 0.1.0)

```swift
// SwiftUI
TLottiePlayer(try? TLottieAnimation(named: "sticker")).frame(width: 160, height: 160)

// UIKit / AppKit
let view = TLottieView()
view.animation = try TLottieAnimation(contentsOf: url)
view.loopMode = .playOnce
view.onFinish = { /* main thread */ }
view.play()

// One frame as an image (e.g. a thumbnail)
let image = try TLottieAnimation(data: data).makeImage(frame: 0, width: 256, height: 256)

// Recolor, skin tone, RGBA output
let options = TLottieAnimation.Options(fitzModifier: .type3,
                                       colorReplacements: [0xFF0000: 0x0A9BF5],
                                       layerColorReplacements: ["eye": 0xFF000000],
                                       pixelFormat: .rgba)
```

### A6. Do / don't

- **Do** render at the displayed pixel size, give each simultaneously playing animation its own instance, and cache frames yourself when the same sticker repeats many times. 512×512 BGRA is 1 MiB per frame.
- **Don't** pass a `.lottie` ZIP; it throws `.invalidData`.
- **Don't** expect text or images to render.
- **Don't** depend on `dkaraush/tlottie` directly from SwiftPM.
- **Don't** bundle third-party Telegram stickers without the author's permission. Stickers belong to their creators.

### A7. Where animations come from

| Source                                                                                                                    | Format                                                                                            | Notes                                     |
| ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| Telegram (Desktop/macOS save; Bot API `getStickerSet` + `getFile`)                                                        | `.tgs`                                                                                            | Check the author's rights before shipping |
| lottiefiles.com                                                                                                           | choose **"Lottie JSON"** when downloading (the default is `.lottie`)                              | check each animation's license            |
| Lordicon, IconScout and similar icon sites                                                                                | Lottie JSON                                                                                       | free tiers often require attribution      |
| After Effects + Bodymovin / LottieFiles plugin; Bodymovin-TG for Telegram-safe output; LottieFiles Creator; Figma plugins | JSON / `.tgs`                                                                                     | stay within the A2 feature list           |
| Conversion                                                                                                                | `gzip -9 -n a.json > a.tgs`; unzip `.lottie` → `a/*.json`; `python-lottie` (`pip install lottie`) |                                           |

---

## B. Working on this repository

### B1. Layout and ownership

| Path                                                                                             | Owner                         | Notes                                                                                                                           |
| ------------------------------------------------------------------------------------------------ | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `src/`, `include/`, `examples/`, `tools/`, `Cargo.*`, `LICENSE`, `README.md`                     | **upstream dkaraush/tlottie** | Never edit here. Rust fixes go upstream as a PR, then get merged back                                                           |
| `Package.swift`                                                                                  | TLottieKit                    | `releaseURL` / `releaseChecksum` lines are rewritten by `apple/release.sh`                                                      |
| `apple/build-xcframework.sh`                                                                     | TLottieKit                    | Rust → `apple/Artifacts/CTLottie.xcframework` (+ `.zip` + checksum)                                                             |
| `apple/exported_symbols.txt`, `apple/module.modulemap`                                           | TLottieKit                    | the exported C surface (`_tlottie_*`) and the `CTLottie` Clang module                                                           |
| `apple/Sources/TLottieKit/`                                                                      | TLottieKit                    | `TLottieAnimation.swift`, `TLottieView.swift`, `TLottiePlayer.swift`, `PlaybackClock.swift`, `Gzip.swift`, `TLottieError.swift` |
| `apple/Tests/TLottieKitTests/`                                                                   | TLottieKit                    | XCTest + `Fixtures/square.json`, `square.tgs`                                                                                   |
| `apple/Examples/TLottieDemo/`                                                                    | TLottieKit                    | XcodeGen `project.yml` (`.xcodeproj` is generated and ignored); `Resources/` has `pulse.json` + free sample `.tgs` stickers     |
| `apple/release.sh`, `.github/workflows/apple.yml`, `.github/README.md`, `AGENTS.md`, `CLAUDE.md` | TLottieKit                    | `.github/README.md` is what GitHub shows; the root `README.md` stays upstream's                                                 |
| `research-cache/`, `apple/build/`, `apple/Artifacts/`, `.build/`                                 | local only                    | gitignored                                                                                                                      |

### B2. Commands

```sh
./apple/build-xcframework.sh                 # ~1 min warm; needs rustup (adds missing targets itself)
SKIP_ZIP=1 ./apple/build-xcframework.sh      # skip the release zip
swift test                                   # macOS, 24 tests
xcodebuild test -scheme TLottieKit -destination 'platform=iOS Simulator,name=<any iPhone>'
TLOTTIEKIT_STICKER=/path/x.tgs TLOTTIEKIT_OUTPUT=/tmp/out swift test --filter ExternalSticker   # frame time + contact sheet
cd apple/Examples/TLottieDemo && xcodegen generate                                             # demo project
apple/release.sh <version>                   # build zip, rewrite Package.swift, commit, tag, push, gh release
git fetch upstream --no-tags && git merge upstream/main                                        # sync tlottie
```

### B3. Invariants (each breaks something silently if violated)

1. **Local binary wins.** `Package.swift` uses `apple/Artifacts/CTLottie.xcframework` when it exists, otherwise the release URL. Consumers never have `Artifacts/`, because it is gitignored. Never commit `Artifacts/`.
2. **Only `_tlottie_*` is exported.** `ld -r -exported_symbols_list` turns every Rust std and compiler-builtins symbol local, so apps that link another Rust static library do not get duplicate symbols. Check after any build: `nm -gU apple/Artifacts/CTLottie.xcframework/*/libtlottie.a` must list only `_tlottie_*`.
3. **Headers go in `Headers/CTLottie/`**, never directly in `Headers/`. Two static XCFrameworks that both ship `Headers/module.modulemap` collide in Xcode.
4. **The arm64 simulator slice is linked for iOS 14.0** (Rust's prebuilt `compiler_builtins` says 14.0). The other slices use iOS 13.0 and macOS 11.0. Keep these in sync with `platforms` in `Package.swift`.
5. **The Rust core is built with `panic=abort`, `--release`, `--features c-api`.** A debug Rust build is ~100× slower.
6. **Instances use `TLOTTIE_CHANNEL_BGRA` for `.bgra`.** The C default is RGBA, which would swap red and blue with no other symptom.
7. **tlottie has no stride parameter.** `render` writes in place only for packed, 4-byte-aligned buffers; everything else goes through `scratch`.
8. **The fork carries no upstream `v*` tags.** SwiftPM would treat them as TLottieKit versions. Always fetch upstream with `--no-tags`.
9. **SwiftUI name clash:** inside `TLottiePlayer`, the stored property is `lottieAnimation`, because `View.animation(_:)` already exists. On AppKit `NSView` has `animation(forKey:)`, so build macOS after touching `TLottieView`.
10. **Swift 6 strict concurrency is on.** `CGImage` crosses threads only inside `RenderedFrame` (`@unchecked Sendable`). The macOS `Timer` block invalidates the timer outside `MainActor.assumeIsolated`.
11. **Licensing.** Never copy code from Telegram-iOS (for example its `TLottieAnimation.mm`): that repository has no LICENSE file, and this package is MIT.

### B4. Definition of done for a change

1. `swift test` passes on macOS.
2. `xcodebuild test -scheme TLottieKit` passes on an iOS simulator.
3. When the build script changed: zero `ld: warning` lines in the build output, and the `nm` check from B3.2 passes.
4. Public API changed → update A3 above and `.github/README.md`.
5. Commits follow the house style: lowercase, past tense, plain English, no `feat:` prefixes.
6. Release only through `apple/release.sh`, which requires a clean tree. After releasing, check from a fresh consumer package that SwiftPM resolves and downloads the new version.

### B5. Context: how others ship tlottie

- **Telegram iOS** vendors the Rust sources and builds them with Bazel `rust_static_library` (`-Copt-level=3`, `-Cpanic=abort`, features `cpu,std,c-api`). It wraps the C API in ObjC++ (`TLottieAnimation.mm`). It picks rlottie or tlottie per render, behind the server killswitch `ios_killswitch_disable_tlottie`.
- **Telegram macOS** links tlottie statically, behind a `TLottieBridge` class and `macos_killswitch_disable_tlottie` (seen in the binary; the source was not inspected).
- **Upstream** ships only `examples/android` (an NDK + JNI `.so` sample app) and `examples/web` (WASM). It has no Apple packaging, and that gap is what TLottieKit fills.

### B6. Known gaps / roadmap

- No measurements on a real iPhone yet. The published numbers come from the Mac and the iOS Simulator.
- No frame cache or buffer pool in `TLottieView`: every frame allocates a new buffer.
- No dotLottie (`.lottie`) support. It needs a ZIP reader; zlib is already linked.
- No Reduce Motion handling.
- Release binaries are built locally. Building them in CI from source would give provenance.
- Upstream contribution in progress: issue `dkaraush/tlottie#17` (opened 2026-10-27) proposes `examples/apple/` (from-source `build.sh`, the Swift package, tests and demo) plus a README section linking to this package. The ready branch is `feature/upstream-apple-example`, based on `upstream/main`. Open the PR against upstream `main` only after the maintainer answers. Never add a root `Package.swift`, binaries or release tooling to upstream.
