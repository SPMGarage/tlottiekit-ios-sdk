import Foundation

/// Errors thrown while loading or rendering an animation.
public enum TLottieError: Error, Equatable, Sendable {
    /// The data is not a Lottie animation tlottie can parse.
    case invalidData
    /// The `.tgs` (gzip) stream is corrupt or truncated.
    case decompressionFailed
    /// The decompressed animation is larger than `Options.maxDecompressedSize`.
    case decompressedSizeLimitExceeded(limit: Int)
    /// No `.tgs`, `.json` or `.lottie.json` resource with this name in the bundle.
    case resourceNotFound(name: String)
    /// A size, stride or buffer argument is out of range.
    case invalidArgument
    /// The destination buffer is smaller than `bytesPerRow * height`.
    case bufferTooSmall
    /// tlottie rejected the frame (for example a render budget was exceeded).
    case renderFailed
}
