import CoreGraphics
import Foundation
import ImageIO
import XCTest
import TLottieKit

/// Renders a real sticker when one is given, for local checks only:
///
///     TLOTTIEKIT_STICKER=/path/to/sticker.tgs TLOTTIEKIT_OUTPUT=/tmp/out swift test --filter ExternalSticker
///
/// It prints the frame time and writes a contact sheet PNG to TLOTTIEKIT_OUTPUT.
/// Without the variable the test is skipped, so no third-party sticker has to
/// live in the repository.
final class ExternalStickerTests: XCTestCase {
    func testRendersExternalSticker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TLOTTIEKIT_STICKER"] else {
            throw XCTSkip("set TLOTTIEKIT_STICKER to a .tgs or .json file")
        }
        let animation = try TLottieAnimation(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(animation.frameCount, 0)

        let side = 512
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let start = CFAbsoluteTimeGetCurrent()
        for frame in 0 ..< animation.frameCount {
            try buffer.withUnsafeMutableBytes { raw in
                try animation.render(frame: Double(frame), into: raw, width: side, height: side, bytesPerRow: side * 4)
            }
        }
        let perFrame = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(animation.frameCount)
        print(String(
            format: "sticker %@: %.0fx%.0f, %d frames @ %.0f fps, %.2f s, %.3f ms/frame at %dpx",
            (path as NSString).lastPathComponent, animation.size.width, animation.size.height,
            animation.frameCount, animation.frameRate, animation.duration, perFrame, side
        ))

        if let output = environment["TLOTTIEKIT_OUTPUT"] {
            try writeContactSheet(animation, to: URL(fileURLWithPath: output))
        }
    }

    private func writeContactSheet(_ animation: TLottieAnimation, to directory: URL) throws {
        let tile = 160
        let columns = 4
        let picks = (0 ..< 8).map { $0 * max(1, animation.frameCount / 8) }
        let rows = (picks.count + columns - 1) / columns
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let context = try XCTUnwrap(CGContext(
            data: nil, width: tile * columns, height: tile * rows, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: tile * columns, height: tile * rows))
        for (index, frame) in picks.enumerated() {
            let image = try animation.makeImage(frame: Double(frame), width: tile, height: tile)
            let x = (index % columns) * tile
            let y = (rows - 1 - index / columns) * tile
            context.draw(image, in: CGRect(x: x, y: y, width: tile, height: tile))
        }
        let sheet = try XCTUnwrap(context.makeImage())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("contact-sheet.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sheet, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        print("contact sheet: \(url.path)")
    }
}
