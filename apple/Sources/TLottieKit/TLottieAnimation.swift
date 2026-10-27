import CoreGraphics
import Foundation
internal import CTLottie

/// Emoji skin tone (Fitzpatrick scale) applied to animations that support it,
/// such as Telegram's animated emoji.
public enum TLottieFitzModifier: Sendable {
    case none
    case type12
    case type3
    case type4
    case type5
    case type6
}

/// Byte order of rendered pixels. Both formats use premultiplied alpha.
public enum TLottiePixelFormat: Sendable {
    /// `[B, G, R, A]` bytes: `CGBitmapInfo.byteOrder32Little` + `premultipliedFirst`,
    /// `kCVPixelFormatType_32BGRA`, `MTLPixelFormat.bgra8Unorm`.
    case bgra
    /// `[R, G, B, A]` bytes: `CGBitmapInfo.byteOrder32Big` + `premultipliedLast`,
    /// `MTLPixelFormat.rgba8Unorm`.
    case rgba
}

/// A parsed Lottie animation, loaded from Lottie JSON, a Telegram `.tgs` file
/// or a dotLottie `.lottie` file.
///
/// One instance can be used from any thread: renders are serialized on an
/// internal lock, because a tlottie instance is single-threaded. Use one
/// instance per animation you play in parallel.
public final class TLottieAnimation: @unchecked Sendable {
    public struct Options: Sendable {
        /// Skin tone for emoji animations.
        public var fitzModifier: TLottieFitzModifier
        /// Replaces colors everywhere they appear. Keys and values are
        /// `0xRRGGBB` (an alpha byte is ignored, the original alpha is kept).
        public var colorReplacements: [UInt32: UInt32]
        /// Recolors every layer whose name starts with the key.
        /// Values are straight-alpha `0xAARRGGBB`.
        public var layerColorReplacements: [String: UInt32]
        /// Byte order of rendered pixels.
        public var pixelFormat: TLottiePixelFormat
        /// Upper bound for a decompressed `.tgs` file or `.lottie` entry, so a
        /// tiny file can not expand into gigabytes. Telegram stickers are well
        /// below 1 MB.
        public var maxDecompressedSize: Int

        public init(
            fitzModifier: TLottieFitzModifier = .none,
            colorReplacements: [UInt32: UInt32] = [:],
            layerColorReplacements: [String: UInt32] = [:],
            pixelFormat: TLottiePixelFormat = .bgra,
            maxDecompressedSize: Int = 8 * 1024 * 1024
        ) {
            self.fitzModifier = fitzModifier
            self.colorReplacements = colorReplacements
            self.layerColorReplacements = layerColorReplacements
            self.pixelFormat = pixelFormat
            self.maxDecompressedSize = maxDecompressedSize
        }
    }

    /// The composition size declared by the animation (`w` x `h`).
    public let size: CGSize
    /// Number of frames. tlottie reports 1 for a composition it can prove static.
    public let frameCount: Int
    /// Frames per second declared by the animation (`fr`), or 0 if it has none.
    public let frameRate: Double
    /// Byte order of every frame this instance renders.
    public let pixelFormat: TLottiePixelFormat

    /// Length of one loop in seconds.
    public var duration: TimeInterval {
        frameRate > 0 ? Double(frameCount) / frameRate : 0
    }

    private let handle: OpaquePointer
    private let lock = NSLock()
    // Packed frame for destinations with row padding; guarded by `lock`.
    private var scratch: [UInt32] = []

    /// Loads Lottie JSON, a gzip-compressed `.tgs` file or a dotLottie `.lottie`
    /// ZIP archive. The format is detected from the data, not the file name.
    /// For a `.lottie` file with several animations, the manifest's initial one
    /// is loaded, or the first one.
    public init(data: Data, options: Options = Options()) throws {
        let json: Data
        if Gzip.isCompressed(data) {
            json = try Gzip.decompress(data, limit: options.maxDecompressedSize)
        } else if DotLottie.isArchive(data) {
            json = try DotLottie.animationJSON(from: data, limit: options.maxDecompressedSize)
        } else {
            json = data
        }
        guard !json.isEmpty, let handle = Self.makeHandle(json: json, options: options) else {
            throw TLottieError.invalidData
        }
        self.handle = handle
        self.pixelFormat = options.pixelFormat
        self.size = CGSize(width: Int(tlottie_width(handle)), height: Int(tlottie_height(handle)))
        self.frameCount = max(1, Int(tlottie_frame_count(handle)))
        let rate = Double(tlottie_frame_rate(handle))
        self.frameRate = rate.isFinite && rate > 0 ? rate : 0
    }

    /// Loads a `.tgs`, Lottie JSON or `.lottie` file.
    public convenience init(contentsOf url: URL, options: Options = Options()) throws {
        try self.init(data: Data(contentsOf: url), options: options)
    }

    /// Loads `name.tgs`, `name.json` or `name.lottie` from a bundle, in that order.
    public convenience init(named name: String, bundle: Bundle = .main, options: Options = Options()) throws {
        let url = ["tgs", "json", "lottie"].lazy.compactMap { bundle.url(forResource: name, withExtension: $0) }.first
        guard let url else {
            throw TLottieError.resourceNotFound(name: name)
        }
        try self.init(contentsOf: url, options: options)
    }

    deinit {
        tlottie_drop(handle)
    }

    /// Renders one frame into a caller-owned buffer of `pixelFormat` pixels.
    ///
    /// - Parameters:
    ///   - frame: Frame number, from 0 to `frameCount - 1`. Fractions interpolate between frames.
    ///   - buffer: At least `bytesPerRow * height` bytes. The whole frame is overwritten.
    ///   - bytesPerRow: Row stride, at least `width * 4`. Row padding is left untouched.
    public func render(
        frame: Double,
        into buffer: UnsafeMutableRawBufferPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws {
        guard width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max), frame.isFinite else {
            throw TLottieError.invalidArgument
        }
        let (packedRowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (strideBytes, strideOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !strideOverflow, bytesPerRow >= packedRowBytes else {
            throw TLottieError.invalidArgument
        }
        guard buffer.count >= strideBytes, let base = buffer.baseAddress else {
            throw TLottieError.bufferTooSmall
        }

        let pixelCount = width * height
        lock.lock()
        defer { lock.unlock() }

        // tlottie writes whole 32-bit words and has no stride parameter, so
        // anything else goes through the packed scratch frame.
        let isAligned = Int(bitPattern: base) % MemoryLayout<UInt32>.alignment == 0
        if bytesPerRow == packedRowBytes, isAligned {
            let status = tlottie_render(
                handle, Float(frame), UInt32(width), UInt32(height),
                base.assumingMemoryBound(to: UInt32.self), pixelCount, 1
            )
            try Self.check(status)
            return
        }

        if scratch.count < pixelCount {
            scratch = [UInt32](repeating: 0, count: pixelCount)
        }
        try scratch.withUnsafeMutableBufferPointer { packed in
            guard let packedBase = packed.baseAddress else {
                throw TLottieError.renderFailed
            }
            let status = tlottie_render(
                handle, Float(frame), UInt32(width), UInt32(height),
                packedBase, pixelCount, 1
            )
            try Self.check(status)
            let source = UnsafeRawPointer(packedBase)
            for row in 0 ..< height {
                (base + row * bytesPerRow).copyMemory(from: source + row * packedRowBytes, byteCount: packedRowBytes)
            }
        }
    }

    /// Renders one frame into a new `CGImage` of `width` x `height` pixels.
    public func makeImage(frame: Double, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw TLottieError.invalidArgument
        }
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        try pixels.withUnsafeMutableBytes { buffer in
            try render(frame: frame, into: buffer, width: width, height: height, bytesPerRow: bytesPerRow)
        }

        let alpha: CGImageAlphaInfo = pixelFormat == .bgra ? .premultipliedFirst : .premultipliedLast
        let byteOrder: CGBitmapInfo = pixelFormat == .bgra ? .byteOrder32Little : .byteOrder32Big
        let bitmapInfo = CGBitmapInfo(rawValue: byteOrder.rawValue | alpha.rawValue)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard
            let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw TLottieError.renderFailed
        }
        return image
    }

    private static func check(_ status: Int32) throws {
        switch status {
        case TLOTTIE_OK.rawValue:
            return
        case TLOTTIE_ERROR_INVALID_ARGUMENT.rawValue:
            throw TLottieError.invalidArgument
        case TLOTTIE_ERROR_BUFFER_TOO_SMALL.rawValue:
            throw TLottieError.bufferTooSmall
        default:
            throw TLottieError.renderFailed
        }
    }

    private static func makeHandle(json: Data, options: Options) -> OpaquePointer? {
        // Sorted so the same options always build the same instance.
        let colors = options.colorReplacements.sorted { $0.key < $1.key }.map {
            TLottieColorReplacement(source_color: $0.key, target_color: $0.value)
        }

        // All layer prefixes share one byte buffer, so their pointers stay
        // valid for the whole call (tlottie copies them while parsing).
        var prefixBytes: [UInt8] = []
        var layers: [(offset: Int, count: Int, color: UInt32)] = []
        for (prefix, color) in options.layerColorReplacements.sorted(by: { $0.key < $1.key }) {
            let bytes = Array(prefix.utf8)
            layers.append((prefixBytes.count, bytes.count, color))
            prefixBytes.append(contentsOf: bytes)
        }

        let channel = options.pixelFormat == .bgra ? TLOTTIE_CHANNEL_BGRA.rawValue : TLOTTIE_CHANNEL_RGBA.rawValue
        let fitz = options.fitzModifier.cValue

        return json.withUnsafeBytes { jsonBytes -> OpaquePointer? in
            prefixBytes.withUnsafeBufferPointer { prefixes -> OpaquePointer? in
                let layerItems = layers.map { layer in
                    TLottieLayerColorReplacement(
                        layer_name_prefix: prefixes.baseAddress.map { $0 + layer.offset },
                        layer_name_prefix_len: layer.count,
                        color: layer.color
                    )
                }
                return layerItems.withUnsafeBufferPointer { layerBuffer -> OpaquePointer? in
                    colors.withUnsafeBufferPointer { colorBuffer -> OpaquePointer? in
                        tlottie_new_with_options(
                            jsonBytes.bindMemory(to: UInt8.self).baseAddress,
                            jsonBytes.count,
                            fitz,
                            layerBuffer.baseAddress,
                            layerBuffer.count,
                            colorBuffer.baseAddress,
                            colorBuffer.count,
                            channel
                        )
                    }
                }
            }
        }
    }
}

extension TLottieFitzModifier {
    fileprivate var cValue: UInt32 {
        switch self {
        case .none: return TLOTTIE_FITZ_NONE.rawValue
        case .type12: return TLOTTIE_FITZ_TYPE_12.rawValue
        case .type3: return TLOTTIE_FITZ_TYPE_3.rawValue
        case .type4: return TLOTTIE_FITZ_TYPE_4.rawValue
        case .type5: return TLOTTIE_FITZ_TYPE_5.rawValue
        case .type6: return TLOTTIE_FITZ_TYPE_6.rawValue
        }
    }
}
