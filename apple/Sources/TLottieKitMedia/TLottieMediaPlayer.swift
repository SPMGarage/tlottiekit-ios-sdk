#if canImport(SwiftUI)
import SwiftUI
import TLottieKit

/// SwiftUI player for a ``TLottieMedia`` GIF or video.
///
/// ```swift
/// TLottieMediaPlayer(try? TLottieMedia(contentsOf: url))
///     .aspectRatio(1, contentMode: .fit)
/// ```
public struct TLottieMediaPlayer {
    private let media: TLottieMedia?
    private let loopMode: TLottieLoopMode
    private let isPlaying: Bool
    private let speed: Double
    private let onFinish: (() -> Void)?

    /// Creates a player.
    ///
    /// - Parameters:
    ///   - media: What to show; nil shows nothing. One ``TLottieMedia`` can
    ///     back any number of players.
    ///   - loopMode: What happens at the end.
    ///   - isPlaying: Plays when true. Finished `.playOnce` media is restarted
    ///     only when this changes from false to true.
    ///   - speed: Playback speed multiplier; 0 freezes the current frame.
    ///   - onFinish: Called on the main thread when `.playOnce` media ends.
    public init(
        _ media: TLottieMedia?,
        loopMode: TLottieLoopMode = .loop,
        isPlaying: Bool = true,
        speed: Double = 1,
        onFinish: (() -> Void)? = nil
    ) {
        self.media = media
        self.loopMode = loopMode
        self.isPlaying = isPlaying
        self.speed = speed
        self.onFinish = onFinish
    }

    /// Remembers what was applied last, so `.playOnce` media that has
    /// finished is not restarted every time SwiftUI updates the view.
    @MainActor
    public final class Coordinator {
        fileprivate var appliedMedia: TLottieMedia?
        fileprivate var appliedIsPlaying: Bool?
    }

    @MainActor
    private func update(_ view: TLottieMediaView, coordinator: Coordinator) {
        view.loopMode = loopMode
        view.speed = speed
        view.onFinish = onFinish

        let mediaChanged = coordinator.appliedMedia !== media
        if mediaChanged {
            view.media = media
            coordinator.appliedMedia = media
        }
        if mediaChanged || coordinator.appliedIsPlaying != isPlaying {
            coordinator.appliedIsPlaying = isPlaying
            if isPlaying {
                view.play()
            } else {
                view.pause()
            }
        }
    }
}

#if canImport(UIKit)
extension TLottieMediaPlayer: UIViewRepresentable {
    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> TLottieMediaView { TLottieMediaView() }

    public func updateUIView(_ view: TLottieMediaView, context: Context) {
        update(view, coordinator: context.coordinator)
    }
}
#elseif canImport(AppKit)
extension TLottieMediaPlayer: NSViewRepresentable {
    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> TLottieMediaView { TLottieMediaView() }

    public func updateNSView(_ view: TLottieMediaView, context: Context) {
        update(view, coordinator: context.coordinator)
    }
}
#endif
#endif
