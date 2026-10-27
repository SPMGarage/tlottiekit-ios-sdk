#if canImport(SwiftUI)
import SwiftUI

/// SwiftUI player for a `TLottieAnimation`.
///
/// ```swift
/// TLottiePlayer(animation, loopMode: .loop)
///     .frame(width: 160, height: 160)
/// ```
public struct TLottiePlayer {
    private let lottieAnimation: TLottieAnimation?
    private let loopMode: TLottieLoopMode
    private let isPlaying: Bool
    private let speed: Double
    private let onFinish: (() -> Void)?

    public init(
        _ animation: TLottieAnimation?,
        loopMode: TLottieLoopMode = .loop,
        isPlaying: Bool = true,
        speed: Double = 1,
        onFinish: (() -> Void)? = nil
    ) {
        self.lottieAnimation = animation
        self.loopMode = loopMode
        self.isPlaying = isPlaying
        self.speed = speed
        self.onFinish = onFinish
    }

    /// Remembers what was applied last, so a `.playOnce` animation that has
    /// finished is not restarted every time SwiftUI updates the view.
    @MainActor
    public final class Coordinator {
        fileprivate var appliedAnimation: TLottieAnimation?
        fileprivate var appliedIsPlaying: Bool?
    }

    @MainActor
    private func update(_ view: TLottieView, coordinator: Coordinator) {
        view.loopMode = loopMode
        view.speed = speed
        view.onFinish = onFinish

        let animationChanged = coordinator.appliedAnimation !== lottieAnimation
        if animationChanged {
            view.animation = lottieAnimation
            coordinator.appliedAnimation = lottieAnimation
        }
        if animationChanged || coordinator.appliedIsPlaying != isPlaying {
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
extension TLottiePlayer: UIViewRepresentable {
    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> TLottieView { TLottieView() }

    public func updateUIView(_ view: TLottieView, context: Context) {
        update(view, coordinator: context.coordinator)
    }
}
#elseif canImport(AppKit)
extension TLottiePlayer: NSViewRepresentable {
    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> TLottieView { TLottieView() }

    public func updateNSView(_ view: TLottieView, context: Context) {
        update(view, coordinator: context.coordinator)
    }
}
#endif
#endif
