import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Errors thrown while loading a GIF or video file.
public enum TLottieMediaError: Error, Equatable, Sendable {
    /// The file is not a GIF, MP4 or QuickTime movie.
    case unsupportedFormat
    /// The file can not be read, or AVFoundation can not decode it.
    case unreadable
    /// The GIF has no frames or the movie has no video track.
    case noFrames
}

/// A looping GIF or video file, such as the H.264 MP4 "GIFs" Telegram sends.
///
/// Loading reads only the header and timing, not the frames. Unlike
/// `TLottieAnimation`, one instance can be shown by any number of views at
/// once: each view decodes it on its own.
public final class TLottieMedia: Sendable {
    /// What kind of file this is, detected from its contents.
    public enum Kind: Sendable, Equatable {
        /// An animated (or still) GIF, decoded with ImageIO.
        case gif
        /// An MP4 or QuickTime movie, decoded by the system. Audio is ignored.
        case video
    }

    /// Whether the file is a GIF or a movie.
    public let kind: Kind
    /// The file. Every view that shows it reads it again on its own.
    public let url: URL
    /// Pixel size as displayed, after a video's rotation is applied.
    public let size: CGSize
    /// Length of one loop in seconds.
    public let duration: TimeInterval

    /// How long each GIF frame is shown, in seconds. Empty for videos.
    let gifFrameDelays: [Double]
    /// Clockwise quarter turns a video needs to be shown upright (0...3).
    let quarterTurns: Int

    /// Loads a `.gif`, `.mp4` or `.mov` file. The format is detected from the
    /// file contents, not the extension.
    ///
    /// This reads the file synchronously. The first call in a process also
    /// loads AVFoundation, so open many files off the main thread.
    ///
    /// - Throws: ``TLottieMediaError/unsupportedFormat`` for anything that is
    ///   not a GIF or movie (WebM included), ``TLottieMediaError/unreadable``
    ///   when the file can not be read, and ``TLottieMediaError/noFrames`` for
    ///   a GIF without frames or a movie without a video track.
    public init(contentsOf url: URL) throws {
        let header: Data
        do {
            header = try Data(contentsOf: url, options: .mappedIfSafe).prefix(12)
        } catch {
            throw TLottieMediaError.unreadable
        }
        self.url = url

        if header.starts(with: Array("GIF8".utf8)) {
            let gif = try GIFInfo(url: url)
            kind = .gif
            size = gif.size
            gifFrameDelays = gif.delays
            duration = gif.delays.reduce(0, +)
            quarterTurns = 0
        } else if header.count >= 8, header.dropFirst(4).prefix(4).elementsEqual(Array("ftyp".utf8)) {
            let video = try VideoInfo(url: url)
            kind = .video
            size = video.size
            duration = video.duration
            gifFrameDelays = []
            quarterTurns = video.quarterTurns
        } else {
            throw TLottieMediaError.unsupportedFormat
        }
    }
}

/// Frame size and timing of a GIF.
struct GIFInfo {
    let size: CGSize
    let delays: [Double]

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw TLottieMediaError.unreadable
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            throw TLottieMediaError.noFrames
        }
        size = CGSize(width: width, height: height)
        delays = (0 ..< count).map { Self.delay(of: source, at: $0) }
    }

    /// Browsers and UIKit show frames with a delay of 10 ms or less for
    /// 100 ms, so files made for the web play at the speed their authors saw.
    static let minimumDelay = 0.011
    static let fallbackDelay = 0.1

    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0
        return delay < minimumDelay ? fallbackDelay : delay
    }
}

/// Display size, length and rotation of a movie's first video track.
struct VideoInfo {
    let size: CGSize
    let duration: TimeInterval
    let quarterTurns: Int

    init(url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard asset.isReadable else {
            throw TLottieMediaError.unreadable
        }
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw TLottieMediaError.noFrames
        }
        let natural = track.naturalSize
        let transform = track.preferredTransform
        // Only rotations by a multiple of 90 degrees occur in practice.
        let turns = Int((atan2(transform.b, transform.a) / (.pi / 2)).rounded())
        quarterTurns = (turns % 4 + 4) % 4
        size = quarterTurns % 2 == 0 ? natural : CGSize(width: natural.height, height: natural.width)
        duration = track.timeRange.duration.seconds
        guard size.width > 0, size.height > 0, duration > 0 else {
            throw TLottieMediaError.noFrames
        }
    }
}
