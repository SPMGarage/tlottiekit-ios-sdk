# ``TLottieKit``

Play Telegram stickers, Lottie JSON and dotLottie animations on iOS and macOS with tlottie, the Rust renderer Telegram uses.

## Overview

TLottieKit wraps [tlottie](https://github.com/dkaraush/tlottie), a fast CPU renderer with SIMD on ARM and x86. It reads three formats and tells them apart by their contents, not their file names:

| File | How it is loaded |
| --- | --- |
| Telegram sticker `.tgs` | gzip, inflated in-process with a size cap |
| Lottie JSON `.json` | passed to tlottie as is |
| dotLottie `.lottie` | ZIP; the manifest's initial animation is played |

Shapes, fills, strokes, gradients, masks, mattes, trim paths and repeaters render. Text layers, image layers, expressions, merge paths and layer effects are skipped without an error, which is exactly what Telegram's sticker rules forbid, so every Telegram sticker renders fully.

For GIF and MP4 loops, add the `TLottieKitMedia` product.

### Play an animation in SwiftUI

```swift
import SwiftUI
import TLottieKit

struct StickerView: View {
    // sticker.tgs in the app bundle
    let animation = try? TLottieAnimation(named: "sticker")

    var body: some View {
        TLottiePlayer(animation)
            .frame(width: 160, height: 160)
    }
}
```

``TLottiePlayer`` has no intrinsic size, so give it a frame or an aspect ratio.

### Play it in UIKit or AppKit

```swift
let view = TLottieView()
view.animation = try TLottieAnimation(contentsOf: url)
view.loopMode = .playOnce
view.onFinish = { print("done") }
view.play()
```

Both players render off the main thread at the view's pixel size and stop working while the view is not in a window.

### Render frames yourself

```swift
let animation = try TLottieAnimation(data: data)
let thumbnail = try animation.makeImage(frame: 0, width: 512, height: 512)
```

``TLottieAnimation/render(frame:into:width:height:bytesPerRow:)`` draws into your own buffer, such as a `CVPixelBuffer` or a Metal texture, in BGRA or RGBA with premultiplied alpha.

### Recolor and change skin tone

```swift
let options = TLottieAnimation.Options(
    // Emoji skin tone
    fitzModifier: .type3,
    // 0xRRGGBB → 0xRRGGBB, everywhere the color appears
    colorReplacements: [0xFF0000: 0x0A9BF5],
    // Layer-name prefix → 0xAARRGGBB
    layerColorReplacements: ["eye": 0xFF000000]
)
let animation = try TLottieAnimation(named: "emoji", options: options)
```

### Threading

``TLottieAnimation`` can be used from any thread, but one instance renders one frame at a time. Give every animation that plays at the same time, such as each cell of a grid, its own instance.

## Topics

### Essentials

- ``TLottieAnimation``
- ``TLottiePlayer``
- ``TLottieView``

### Loading and rendering

- ``TLottieAnimation/Options``
- ``TLottieFitzModifier``
- ``TLottiePixelFormat``
- ``TLottieError``

### Playback

- ``TLottieLoopMode``
- ``TLottiePlatformView``
