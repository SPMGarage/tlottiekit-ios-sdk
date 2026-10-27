import CoreGraphics
import Foundation
import XCTest
@testable import TLottieKit

/// The fixture is a 100x100, 60 fps, 60-frame composition with a red 50x50
/// square in the top-left quadrant whose opacity fades from 100% to 0%.
/// The fade is there on purpose: tlottie reports 1 frame for a composition
/// it can prove static.
final class TLottieAnimationTests: XCTestCase {
    private let side = 100

    // MARK: Loading

    func testLoadsJSONMetadata() throws {
        let animation = try TLottieAnimation(data: Fixtures.json)
        XCTAssertEqual(animation.size, CGSize(width: 100, height: 100))
        XCTAssertEqual(animation.frameCount, 60)
        XCTAssertEqual(animation.frameRate, 60)
        XCTAssertEqual(animation.duration, 1, accuracy: 0.0001)
        XCTAssertEqual(animation.pixelFormat, .bgra)
    }

    func testTGSRendersExactlyLikeItsJSON() throws {
        let json = try TLottieAnimation(data: Fixtures.json)
        let tgs = try TLottieAnimation(data: Fixtures.tgs)
        XCTAssertEqual(tgs.size, json.size)
        XCTAssertEqual(tgs.frameCount, json.frameCount)
        XCTAssertEqual(tgs.frameRate, json.frameRate)
        for frame in [0.0, 30, 59] {
            XCTAssertEqual(try render(tgs, frame: frame), try render(json, frame: frame), "frame \(frame)")
        }
    }

    func testLoadsFromURLAndBundleName() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "square", withExtension: "tgs", subdirectory: "Fixtures"))
        XCTAssertEqual(try TLottieAnimation(contentsOf: url).frameCount, 60)

        XCTAssertThrowsError(try TLottieAnimation(named: "missing", bundle: .module)) { error in
            XCTAssertEqual(error as? TLottieError, .resourceNotFound(name: "missing"))
        }
    }

    func testRejectsDataThatIsNotLottie() {
        for data in [Data(), Data("not lottie".utf8), Data("{\"v\":1}".utf8)] {
            XCTAssertThrowsError(try TLottieAnimation(data: data)) { error in
                XCTAssertEqual(error as? TLottieError, .invalidData)
            }
        }
    }

    func testRejectsTruncatedTGS() {
        let truncated = Fixtures.tgs.prefix(Fixtures.tgs.count / 2)
        XCTAssertThrowsError(try TLottieAnimation(data: truncated)) { error in
            XCTAssertEqual(error as? TLottieError, .decompressionFailed)
        }
    }

    func testDecompressionStopsAtTheSizeLimit() {
        let options = TLottieAnimation.Options(maxDecompressedSize: 100)
        XCTAssertThrowsError(try TLottieAnimation(data: Fixtures.tgs, options: options)) { error in
            XCTAssertEqual(error as? TLottieError, .decompressedSizeLimitExceeded(limit: 100))
        }
    }

    // MARK: Pixels

    func testBGRAByteOrderAndOrientation() throws {
        let pixels = try render(TLottieAnimation(data: Fixtures.json), frame: 0)
        // Red, fully opaque, in the top-left quadrant: [B, G, R, A].
        XCTAssertEqual(pixel(pixels, x: 10, y: 10), [0, 0, 255, 255])
        // The other three quadrants stay transparent.
        XCTAssertEqual(pixel(pixels, x: 75, y: 10), [0, 0, 0, 0])
        XCTAssertEqual(pixel(pixels, x: 10, y: 75), [0, 0, 0, 0])
        XCTAssertEqual(pixel(pixels, x: 75, y: 75), [0, 0, 0, 0])
    }

    func testRGBAByteOrder() throws {
        let animation = try TLottieAnimation(data: Fixtures.json, options: .init(pixelFormat: .rgba))
        let pixels = try render(animation, frame: 0)
        XCTAssertEqual(pixel(pixels, x: 10, y: 10), [255, 0, 0, 255])
    }

    func testAnimatedOpacityIsPremultiplied() throws {
        let pixels = try render(TLottieAnimation(data: Fixtures.json), frame: 30)
        let value = pixel(pixels, x: 10, y: 10)
        // Half way through the fade: about 50% alpha, red premultiplied to match.
        XCTAssertEqual(value[0], 0)
        XCTAssertEqual(value[1], 0)
        XCTAssertTrue((118 ... 138).contains(value[3]), "alpha \(value[3])")
        XCTAssertEqual(Int(value[2]), Int(value[3]), accuracy: 1)
    }

    func testColorReplacement() throws {
        let options = TLottieAnimation.Options(colorReplacements: [0xFF0000: 0x0000FF])
        let pixels = try render(TLottieAnimation(data: Fixtures.json, options: options), frame: 0)
        XCTAssertEqual(pixel(pixels, x: 10, y: 10), [255, 0, 0, 255])
    }

    func testLayerColorReplacementMatchesNamePrefix() throws {
        let options = TLottieAnimation.Options(layerColorReplacements: ["red": 0xFF00FF00])
        let pixels = try render(TLottieAnimation(data: Fixtures.json, options: options), frame: 0)
        XCTAssertEqual(pixel(pixels, x: 10, y: 10), [0, 255, 0, 255])
    }

    func testRowPaddingIsLeftUntouched() throws {
        let animation = try TLottieAnimation(data: Fixtures.json)
        let bytesPerRow = side * 4 + 20
        var buffer = [UInt8](repeating: 0xAB, count: bytesPerRow * side)
        try buffer.withUnsafeMutableBytes { raw in
            try animation.render(frame: 0, into: raw, width: side, height: side, bytesPerRow: bytesPerRow)
        }
        for row in 0 ..< side {
            let padding = buffer[(row * bytesPerRow + side * 4) ..< ((row + 1) * bytesPerRow)]
            XCTAssertTrue(padding.allSatisfy { $0 == 0xAB }, "row \(row) padding was written")
        }
        let offset = 10 * bytesPerRow + 10 * 4
        XCTAssertEqual(Array(buffer[offset ..< offset + 4]), [0, 0, 255, 255])
        let transparent = 10 * bytesPerRow + 75 * 4
        XCTAssertEqual(Array(buffer[transparent ..< transparent + 4]), [0, 0, 0, 0])
    }

    func testUnalignedBufferRendersTheSamePixels() throws {
        let animation = try TLottieAnimation(data: Fixtures.json)
        let expected = try render(animation, frame: 0)
        let bytes = side * side * 4
        var storage = [UInt8](repeating: 0, count: bytes + 1)
        try storage.withUnsafeMutableBytes { raw in
            let shifted = UnsafeMutableRawBufferPointer(rebasing: raw[1...])
            try animation.render(frame: 0, into: shifted, width: side, height: side, bytesPerRow: side * 4)
        }
        XCTAssertEqual(Array(storage[1...]), expected)
    }

    func testRejectsBadArguments() throws {
        let animation = try TLottieAnimation(data: Fixtures.json)
        var buffer = [UInt8](repeating: 0, count: 16)
        try buffer.withUnsafeMutableBytes { raw in
            XCTAssertThrowsError(try animation.render(frame: 0, into: raw, width: 0, height: 1, bytesPerRow: 4)) {
                XCTAssertEqual($0 as? TLottieError, .invalidArgument)
            }
            XCTAssertThrowsError(try animation.render(frame: 0, into: raw, width: 2, height: 1, bytesPerRow: 4)) {
                XCTAssertEqual($0 as? TLottieError, .invalidArgument)
            }
            XCTAssertThrowsError(try animation.render(frame: .nan, into: raw, width: 1, height: 1, bytesPerRow: 4)) {
                XCTAssertEqual($0 as? TLottieError, .invalidArgument)
            }
            XCTAssertThrowsError(try animation.render(frame: 0, into: raw, width: 4, height: 4, bytesPerRow: 16)) {
                XCTAssertEqual($0 as? TLottieError, .bufferTooSmall)
            }
        }
    }

    func testMakeImage() throws {
        let animation = try TLottieAnimation(data: Fixtures.json)
        let image = try animation.makeImage(frame: 0, width: 64, height: 64)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
        XCTAssertEqual(image.bitsPerPixel, 32)
        XCTAssertEqual(image.alphaInfo, .premultipliedFirst)
        XCTAssertEqual(image.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little)

        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let offset = 5 * image.bytesPerRow + 5 * 4
        XCTAssertEqual(Array(data[offset ..< offset + 4]), [0, 0, 255, 255])
    }

    func testOneInstanceCanBeSharedBetweenThreads() throws {
        let animation = try TLottieAnimation(data: Fixtures.json)
        let expected = try (0 ..< 8).map { try render(animation, frame: Double($0 * 7)) }
        let results = ResultsBox(count: 8)
        let side = self.side
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            var buffer = [UInt8](repeating: 0, count: side * side * 4)
            let rendered: Void? = try? buffer.withUnsafeMutableBytes { raw in
                try animation.render(frame: Double(index * 7), into: raw, width: side, height: side, bytesPerRow: side * 4)
            }
            results.set(index, rendered == nil ? nil : buffer)
        }
        XCTAssertEqual(results.values, expected)
    }

    // MARK: Helpers

    private func render(_ animation: TLottieAnimation, frame: Double) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        try buffer.withUnsafeMutableBytes { raw in
            try animation.render(frame: frame, into: raw, width: side, height: side, bytesPerRow: side * 4)
        }
        return buffer
    }

    private func pixel(_ pixels: [UInt8], x: Int, y: Int) -> [UInt8] {
        let offset = (y * side + x) * 4
        return Array(pixels[offset ..< offset + 4])
    }
}

private final class ResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[UInt8]?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ value: [UInt8]?) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    var values: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { $0 }
    }
}

enum Fixtures {
    static let json = load("square", "json")
    static let tgs = load("square", "tgs")

    private static func load(_ name: String, _ ext: String) -> Data {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            let data = try? Data(contentsOf: url)
        else {
            fatalError("missing fixture \(name).\(ext)")
        }
        return data
    }
}
