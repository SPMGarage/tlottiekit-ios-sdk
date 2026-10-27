# ``TLottieKitMedia``

Loop GIFs and MP4 videos the way Telegram plays its GIFs: silent, seamless and only while on screen.

## Overview

Telegram sends "GIFs" as silent H.264 MP4 files and plays them in a loop. TLottieKitMedia does the same with Apple's own frameworks, and plays real GIFs too. The format is detected from the file contents:

| File | How it is played |
| --- | --- |
| `.mp4`, `.mov` (H.264, HEVC) | `AVAssetReader` hands compressed frames to an `AVSampleBufferDisplayLayer`; the system decodes them, usually in hardware |
| `.gif` | ImageIO decodes each frame with its own delay and transparency |

- **No audio.** The audio track is never read, so the user's music keeps playing.
- **Seamless loops.** A `CMTimebase` drives playback instead of a display link. Every loop is timed to follow the previous one; pausing and changing speed only change the timebase rate.
- **Off screen costs nothing.** A view decodes only while it is in a window, and starts again from the first frame when it comes back.
- **Browser timing for GIFs.** Frames with a delay of 10 ms or less play for 100 ms, as in browsers.
- **Upright video.** A rotation stored in the movie, as phones record it, is applied.

### Play a GIF or video in SwiftUI

```swift
import SwiftUI
import TLottieKitMedia

struct GIFView: View {
    // A .gif, .mp4 or .mov file
    let media = try? TLottieMedia(contentsOf: url)

    var body: some View {
        TLottieMediaPlayer(media)
            .aspectRatio(1, contentMode: .fit)
    }
}
```

### Play it in UIKit or AppKit

```swift
let view = TLottieMediaView()
view.media = try TLottieMedia(contentsOf: url)
view.loopMode = .playOnce
view.onFinish = { print("done") }
view.play()
```

### Grids

One ``TLottieMedia`` can back any number of players, for example every cell of a grid: it only holds the file's address, size and length, and each view decodes on its own. Loading reads the file synchronously, and the first file in a process also loads AVFoundation, so open many files off the main thread.

### What is not supported

WebM / VP9 files, which Telegram uses for video stickers, throw ``TLottieMediaError/unsupportedFormat``. H.264 has no alpha channel, so MP4 loops are opaque. GIF transparency works, but its edges are hard, because a GIF pixel is either fully transparent or not at all.

## Topics

### Essentials

- ``TLottieMedia``
- ``TLottieMediaPlayer``
- ``TLottieMediaView``

### Errors

- ``TLottieMediaError``
