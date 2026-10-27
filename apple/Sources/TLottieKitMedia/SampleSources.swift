import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO

/// One pass over a GIF or video as display-ready sample buffers, in
/// presentation order for GIFs and decode order for videos. Not thread-safe:
/// each source is used from one queue.
protocol SampleSource: AnyObject {
    /// Where the samples' timestamps start, and how long one pass lasts.
    var timeRange: CMTimeRange { get }
    /// The next sample, or nil at the end of the pass.
    func nextSample() throws -> CMSampleBuffer?
    /// Goes back to the start of the pass.
    func restart()
}

/// Makes the source for a media file.
func makeSampleSource(for media: TLottieMedia) throws -> SampleSource {
    switch media.kind {
    case .gif:
        return try GIFSampleSource(media: media)
    case .video:
        return try VideoSampleSource(url: media.url)
    }
}

/// Hands out a video track's compressed samples as they are stored. The
/// display layer decodes them, so decoding uses the system's (usually
/// hardware) H.264 / HEVC decoder and no audio is ever read.
final class VideoSampleSource: SampleSource {
    let timeRange: CMTimeRange
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    init(url: URL) throws {
        asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw TLottieMediaError.noFrames
        }
        self.track = track
        // Passthrough samples carry media times, which the edit list maps onto
        // the presentation timeline. x264, for one, starts its media at the
        // B-frame delay, so a clip shown from 0 to 1 s has media times 0.2-1.1.
        let presentation = track.timeRange
        let mediaStart = track.segments.first { !$0.isEmpty }?.timeMapping.source.start ?? presentation.start
        timeRange = CMTimeRange(start: mediaStart, duration: presentation.duration)
    }

    func nextSample() throws -> CMSampleBuffer? {
        if reader == nil {
            try startReading()
        }
        guard let reader, let output else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            // Skip markers without media, which the display layer can not use.
            if CMSampleBufferGetNumSamples(sample) > 0 {
                return sample
            }
        }
        if reader.status == .failed {
            throw TLottieMediaError.unreadable
        }
        return nil
    }

    func restart() {
        reader?.cancelReading()
        reader = nil
        output = nil
    }

    private func startReading() throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TLottieMediaError.unreadable
        }
        // nil settings: compressed samples, no decoding here.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TLottieMediaError.unreadable
        }
        reader.add(output)
        guard reader.startReading() else {
            throw TLottieMediaError.unreadable
        }
        self.reader = reader
        self.output = output
    }
}

/// Decodes GIF frames with ImageIO into BGRA pixel buffers. ImageIO returns
/// each frame already composited over the previous ones.
final class GIFSampleSource: SampleSource {
    /// Frames larger than this are scaled down; the layer scales them again.
    static let maximumDimension = 2048

    let timeRange: CMTimeRange
    private let source: CGImageSource
    private let delays: [CMTime]
    private let pixelWidth: Int
    private let pixelHeight: Int
    private var pool: CVPixelBufferPool?
    private var index = 0
    private var time = CMTime.zero

    init(media: TLottieMedia) throws {
        guard let source = CGImageSourceCreateWithURL(media.url as CFURL, nil) else {
            throw TLottieMediaError.unreadable
        }
        self.source = source
        // GIF delays are whole hundredths of a second.
        delays = media.gifFrameDelays.map { CMTime(value: CMTimeValue(($0 * 100).rounded()), timescale: 100) }
        timeRange = CMTimeRange(start: .zero, duration: delays.reduce(.zero, +))
        let scale = min(1, CGFloat(Self.maximumDimension) / max(media.size.width, media.size.height))
        pixelWidth = max(1, Int((media.size.width * scale).rounded()))
        pixelHeight = max(1, Int((media.size.height * scale).rounded()))
    }

    func nextSample() throws -> CMSampleBuffer? {
        guard index < delays.count else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, index, options) else {
            throw TLottieMediaError.unreadable
        }
        let timing = CMSampleTimingInfo(duration: delays[index], presentationTimeStamp: time, decodeTimeStamp: .invalid)
        let sample = try makeSample(from: image, timing: timing)
        time = time + delays[index]
        index += 1
        return sample
    }

    func restart() {
        index = 0
        time = .zero
    }

    private func makeSample(from image: CGImage, timing: CMSampleTimingInfo) throws -> CMSampleBuffer {
        let pixelBuffer = try makePixelBuffer()
        try draw(image, into: pixelBuffer)

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
        )
        var timing = timing
        var sample: CMSampleBuffer?
        guard let format,
              CMSampleBufferCreateReadyWithImageBuffer(
                  allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
                  sampleTiming: &timing, sampleBufferOut: &sample
              ) == noErr,
              let sample
        else {
            throw TLottieMediaError.unreadable
        }
        return sample
    }

    /// Pixel buffers come from a pool, so frames the layer has shown are reused.
    private func makePixelBuffer() throws -> CVPixelBuffer {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: pixelWidth,
                kCVPixelBufferHeightKey: pixelHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer
        else {
            throw TLottieMediaError.unreadable
        }
        return buffer
    }

    private func draw(_ image: CGImage, into buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw TLottieMediaError.unreadable
        }
        let rect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        // Pooled buffers still hold an older frame, and GIFs can be transparent.
        context.clear(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
    }
}

/// Plays a source again and again (or once) on one continuous timeline:
/// every pass is shifted to start where the previous one ended, so the
/// display layer never has to be flushed between loops.
final class LoopingSampleFeeder {
    var loops: Bool
    /// Timeline time at which the current pass started.
    private(set) var passStart = CMTime.zero
    private let source: SampleSource
    private var hasSamplesInPass = false

    init(source: SampleSource, loops: Bool) {
        self.source = source
        self.loops = loops
    }

    /// Timeline time at which the current pass ends.
    var passEnd: CMTime { passStart + source.timeRange.duration }

    /// The next sample on the timeline, or nil once a pass ends without looping.
    func next() throws -> CMSampleBuffer? {
        if let sample = try source.nextSample() {
            hasSamplesInPass = true
            return try sample.shifted(by: passStart - source.timeRange.start)
        }
        // A pass without samples would loop forever, so it ends playback.
        guard loops, hasSamplesInPass else { return nil }
        passStart = passEnd
        hasSamplesInPass = false
        source.restart()
        return try next()
    }

    func reset() {
        source.restart()
        passStart = .zero
        hasSamplesInPass = false
    }
}

extension CMSampleBuffer {
    /// A copy with every presentation and decode time moved by `offset`.
    func shifted(by offset: CMTime) throws -> CMSampleBuffer {
        guard offset != .zero else { return self }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + offset
            }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: self, sampleTimingEntryCount: count,
            sampleTimingArray: &timings, sampleBufferOut: &copy
        ) == noErr, let copy else {
            throw TLottieMediaError.unreadable
        }
        return copy
    }
}
