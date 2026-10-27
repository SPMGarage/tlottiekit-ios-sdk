import Foundation

/// What happens when playback reaches the last frame.
public enum TLottieLoopMode: Sendable, Equatable {
    /// Start again from the first frame.
    case loop
    /// Stop on the last frame.
    case playOnce
}

/// Playback position in frames. Kept apart from the view so the timing rules
/// can be tested without a display link.
struct PlaybackClock: Equatable {
    private(set) var position: Double = 0

    var frame: Int { Int(position) }

    mutating func reset() {
        position = 0
    }

    mutating func seek(toFrame frame: Int, frameCount: Int) {
        position = Double(min(max(0, frame), max(0, frameCount - 1)))
    }

    func isAtEnd(frameCount: Int) -> Bool {
        frame >= frameCount - 1
    }

    /// Moves playback forward. Returns true when a `.playOnce` animation
    /// has just reached its end.
    mutating func advance(
        seconds: Double,
        framesPerSecond: Double,
        frameCount: Int,
        loopMode: TLottieLoopMode
    ) -> Bool {
        guard seconds > 0, framesPerSecond > 0, frameCount > 1 else {
            return false
        }
        position += seconds * framesPerSecond
        let count = Double(frameCount)
        guard position >= count else {
            return false
        }
        switch loopMode {
        case .loop:
            position = position.truncatingRemainder(dividingBy: count)
            return false
        case .playOnce:
            position = count - 1
            return true
        }
    }
}
