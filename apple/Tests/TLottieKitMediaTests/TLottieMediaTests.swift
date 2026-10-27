import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import TLottieKitMedia

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Fixtures:
/// - pulse.gif: 16x16, three frames on a transparent background, shown for
///   0.05 s, 0.25 s and 0 s (which must play as 0.1 s, as in browsers).
/// - pulse.mp4: 64x64 H.264, 10 frames at 10 fps with B-frames and no audio,
///   like the MP4 "GIFs" Telegram sends.
/// - rotated.mp4: 64x32 H.264 with a 90 degree display rotation.
final class TLottieMediaTests: XCTestCase {
    // MARK: Loading

    func testLoadsGIF() throws {
        let media = try TLottieMedia(contentsOf: Fixtures.url("pulse", "gif"))
        XCTAssertEqual(media.kind, .gif)
        XCTAssertEqual(media.size, CGSize(width: 16, height: 16))
        XCTAssertEqual(media.gifFrameDelays.count, 3)
        for (delay, expected) in zip(media.gifFrameDelays, [0.05, 0.25, 0.1]) {
            XCTAssertEqual(delay, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(media.duration, 0.4, accuracy: 0.0001)
    }

    func testLoadsVideo() throws {
        let media = try TLottieMedia(contentsOf: Fixtures.url("pulse", "mp4"))
        XCTAssertEqual(media.kind, .video)
        XCTAssertEqual(media.size, CGSize(width: 64, height: 64))
        XCTAssertEqual(media.duration, 1, accuracy: 0.01)
        XCTAssertEqual(media.quarterTurns, 0)
    }

    func testRotatedVideoReportsItsUprightSize() throws {
        let media = try TLottieMedia(contentsOf: Fixtures.url("rotated", "mp4"))
        XCTAssertEqual(media.size, CGSize(width: 32, height: 64))
        XCTAssertEqual(media.quarterTurns % 2, 1)
    }

    func testDetectsTheFormatFromTheContents() throws {
        let renamed = try Fixtures.temporaryCopy(of: Fixtures.url("pulse", "gif"), named: "looks-like-a.mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: renamed.deletingLastPathComponent()) }
        XCTAssertEqual(try TLottieMedia(contentsOf: renamed).kind, .gif)
    }

    func testRejectsFilesThatAreNotMedia() throws {
        let json = try Fixtures.temporaryFile(named: "animation.json", contents: Data("{\"v\":\"5.7\"}".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(at: json.deletingLastPathComponent()) }
        XCTAssertThrowsError(try TLottieMedia(contentsOf: json)) { error in
            XCTAssertEqual(error as? TLottieMediaError, .unsupportedFormat)
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).mp4")
        XCTAssertThrowsError(try TLottieMedia(contentsOf: missing)) { error in
            XCTAssertEqual(error as? TLottieMediaError, .unreadable)
        }
    }

    // MARK: Samples

    func testGIFSamplesFollowTheFrameDelays() throws {
        let source = try GIFSampleSource(media: TLottieMedia(contentsOf: Fixtures.url("pulse", "gif")))
        let samples = try Fixtures.drain(source)
        XCTAssertEqual(samples.map(\.presentationTimeStamp.seconds), [0, 0.05, 0.3])
        XCTAssertEqual(samples.map(\.duration.seconds), [0.05, 0.25, 0.1])

        let pixels = try XCTUnwrap(samples.first?.imageBuffer)
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 16)
        XCTAssertEqual(CVPixelBufferGetHeight(pixels), 16)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixels), kCVPixelFormatType_32BGRA)

        source.restart()
        XCTAssertEqual(try source.nextSample()?.presentationTimeStamp, .zero)
    }

    func testVideoSamplesCoverOnePass() throws {
        let source = try VideoSampleSource(url: Fixtures.url("pulse", "mp4"))
        let samples = try Fixtures.drain(source)
        XCTAssertEqual(samples.count, 10)
        let times = samples.map(\.presentationTimeStamp).sorted()
        XCTAssertEqual(Set(times).count, 10, "every frame once")
        XCTAssertTrue(times.allSatisfy { source.timeRange.containsTime($0) })
        // Compressed samples: the display layer decodes them.
        XCTAssertNil(samples.first?.imageBuffer)

        source.restart()
        XCTAssertEqual(try source.nextSample()?.presentationTimeStamp, samples.first?.presentationTimeStamp)
    }

    func testFeederShiftsEveryPassToFollowThePreviousOne() throws {
        let gif = try GIFSampleSource(media: TLottieMedia(contentsOf: Fixtures.url("pulse", "gif")))
        let feeder = LoopingSampleFeeder(source: gif, loops: true)
        let times = try (0 ..< 7).map { _ in try XCTUnwrap(feeder.next()).presentationTimeStamp.seconds }
        let expected = [0, 0.05, 0.3, 0.4, 0.45, 0.7, 0.8]
        for (time, value) in zip(times, expected) {
            XCTAssertEqual(time, value, accuracy: 0.0001)
        }
    }

    func testFeederLoopsVideoWithoutAGap() throws {
        let video = try VideoSampleSource(url: Fixtures.url("pulse", "mp4"))
        let feeder = LoopingSampleFeeder(source: video, loops: true)
        let samples = try (0 ..< 20).map { _ in try XCTUnwrap(feeder.next()) }
        let first = samples[..<10].map(\.presentationTimeStamp.seconds).sorted()
        let second = samples[10...].map(\.presentationTimeStamp.seconds).sorted()
        // The first frame shows at once and the last one before the pass ends.
        XCTAssertEqual(try XCTUnwrap(first.first), 0, accuracy: 0.0001)
        XCTAssertLessThan(try XCTUnwrap(first.last), video.timeRange.duration.seconds)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(b - a, video.timeRange.duration.seconds, accuracy: 0.0001)
        }
    }

    func testFeederStopsAfterOnePassUnlessLoopingIsTurnedOn() throws {
        let gif = try GIFSampleSource(media: TLottieMedia(contentsOf: Fixtures.url("pulse", "gif")))
        let feeder = LoopingSampleFeeder(source: gif, loops: false)
        for _ in 0 ..< 3 {
            XCTAssertNotNil(try feeder.next())
        }
        XCTAssertNil(try feeder.next())
        XCTAssertEqual(feeder.passEnd.seconds, 0.4, accuracy: 0.0001)

        feeder.loops = true
        XCTAssertEqual(try XCTUnwrap(feeder.next()).presentationTimeStamp.seconds, 0.4, accuracy: 0.0001)
    }

    // MARK: Playback

    @MainActor
    func testPlayOnceFinishesAfterOnePass() throws {
        for name in [("pulse", "gif"), ("pulse", "mp4")] {
            let media = try TLottieMedia(contentsOf: Fixtures.url(name.0, name.1))
            let finished = expectation(description: "finished \(name.1)")
            let start = Date()
            let playback = try MediaPlayback(media: media, loops: false) { finished.fulfill() }
            playback.setRate(1)
            wait(for: [finished], timeout: media.duration + 2)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), media.duration * 0.9, name.1)
            playback.invalidate()
        }
    }

    @MainActor
    func testSpeedAndPauseFollowTheTimebase() throws {
        let media = try TLottieMedia(contentsOf: Fixtures.url("pulse", "mp4"))

        // At 4x a one-second clip ends well before one second.
        let fast = expectation(description: "fast")
        let start = Date()
        let playback = try MediaPlayback(media: media, loops: false) { fast.fulfill() }
        playback.setRate(4)
        wait(for: [fast], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
        playback.invalidate()

        // Paused, or looping, it never ends.
        let never = expectation(description: "never")
        never.isInverted = true
        let paused = try MediaPlayback(media: media, loops: false) { never.fulfill() }
        let looping = try MediaPlayback(media: media, loops: true) { never.fulfill() }
        looping.setRate(4)
        wait(for: [never], timeout: 1.5)
        paused.invalidate()
        looping.invalidate()
    }
}

extension TLottieMediaTests {
    @MainActor
    func testViewPlaysOnlyInAWindowAndReportsTheEnd() throws {
        let view = TLottieMediaView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        view.loopMode = .playOnce
        view.media = try TLottieMedia(contentsOf: Fixtures.url("pulse", "gif"))
        let finished = expectation(description: "finished")
        view.onFinish = { finished.fulfill() }
        view.play()
        XCTAssertTrue(view.isPlaying)

        let window = Fixtures.window(containing: view)
        wait(for: [finished], timeout: 3)
        XCTAssertFalse(view.isPlaying)
        withExtendedLifetime(window) {}
    }
}

enum Fixtures {
    /// A window keeps the view playing; the caller must keep it alive.
    @MainActor
    static func window(containing view: TLottieMediaView) -> AnyObject {
        #if canImport(UIKit)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(view)
        window.isHidden = false
        #else
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        #endif
        return window
    }

    static func url(_ name: String, _ ext: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name).\(ext)")
        }
        return url
    }

    static func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    static func temporaryCopy(of url: URL, named name: String) throws -> URL {
        try temporaryFile(named: name, contents: Data(contentsOf: url))
    }

    static func drain(_ source: SampleSource) throws -> [CMSampleBuffer] {
        var samples: [CMSampleBuffer] = []
        while let sample = try source.nextSample() {
            samples.append(sample)
        }
        return samples
    }
}
