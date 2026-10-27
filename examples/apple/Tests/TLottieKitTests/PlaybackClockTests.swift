import XCTest
@testable import TLottieKit

final class PlaybackClockTests: XCTestCase {
    func testAdvancesByElapsedTimeTimesFrameRate() {
        var clock = PlaybackClock()
        XCTAssertFalse(clock.advance(seconds: 0.5, framesPerSecond: 60, frameCount: 60, loopMode: .loop))
        XCTAssertEqual(clock.frame, 30)
    }

    func testLoopWrapsAround() {
        var clock = PlaybackClock()
        XCTAssertFalse(clock.advance(seconds: 1.25, framesPerSecond: 60, frameCount: 60, loopMode: .loop))
        XCTAssertEqual(clock.frame, 15)
    }

    func testLongPauseStillLandsInsideTheLoop() {
        var clock = PlaybackClock()
        _ = clock.advance(seconds: 3600.1, framesPerSecond: 60, frameCount: 60, loopMode: .loop)
        XCTAssertTrue((0 ..< 60).contains(clock.frame))
    }

    func testPlayOnceStopsOnTheLastFrame() {
        var clock = PlaybackClock()
        XCTAssertFalse(clock.advance(seconds: 0.9, framesPerSecond: 60, frameCount: 60, loopMode: .playOnce))
        XCTAssertTrue(clock.advance(seconds: 0.2, framesPerSecond: 60, frameCount: 60, loopMode: .playOnce))
        XCTAssertEqual(clock.frame, 59)
        XCTAssertTrue(clock.isAtEnd(frameCount: 60))
    }

    func testSpeedIsPartOfTheFrameRate() {
        var clock = PlaybackClock()
        _ = clock.advance(seconds: 0.25, framesPerSecond: 60 * 2, frameCount: 60, loopMode: .loop)
        XCTAssertEqual(clock.frame, 30)
    }

    func testStaticOrBrokenAnimationsNeverMove() {
        var clock = PlaybackClock()
        XCTAssertFalse(clock.advance(seconds: 1, framesPerSecond: 0, frameCount: 60, loopMode: .playOnce))
        XCTAssertFalse(clock.advance(seconds: 1, framesPerSecond: 60, frameCount: 1, loopMode: .playOnce))
        XCTAssertFalse(clock.advance(seconds: -1, framesPerSecond: 60, frameCount: 60, loopMode: .playOnce))
        XCTAssertEqual(clock.frame, 0)
    }

    func testSeekIsClamped() {
        var clock = PlaybackClock()
        clock.seek(toFrame: 500, frameCount: 60)
        XCTAssertEqual(clock.frame, 59)
        clock.seek(toFrame: -3, frameCount: 60)
        XCTAssertEqual(clock.frame, 0)
    }
}
