import AVFoundation
import QuartzCore
import TLottieKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Plays a ``TLottieMedia`` GIF or video the way Telegram plays GIFs: muted,
/// aspect-fit, looping (or once), and only while the view is in a window.
///
/// A view that leaves its window releases its decoder and costs nothing; when
/// it comes back it starts again from the first frame.
///
/// ```swift
/// let view = TLottieMediaView()
/// // A .gif, .mp4 or .mov file
/// view.media = try TLottieMedia(contentsOf: url)
/// view.play()
/// ```
///
/// In SwiftUI, use ``TLottieMediaPlayer`` instead.
@MainActor
open class TLottieMediaView: TLottiePlatformView {
    /// The GIF or video to show. Setting a new one shows its first frame;
    /// call `play()` to start it.
    public var media: TLottieMedia? {
        didSet {
            guard media !== oldValue else { return }
            mediaDidChange()
        }
    }

    /// What happens at the end. The default is `.loop`.
    public var loopMode: TLottieLoopMode = .loop {
        didSet { playback?.setLoops(loopMode == .loop) }
    }

    /// Playback speed multiplier. 0 freezes the current frame.
    public var speed: Double = 1 {
        didSet {
            if speed < 0 { speed = 0 }
            updateRate()
        }
    }

    /// Called on the main thread when `.playOnce` media reaches its end.
    public var onFinish: (() -> Void)?

    /// Whether playback is running. It turns false when `.playOnce` media ends.
    public private(set) var isPlaying = false

    private var playback: MediaPlayback?
    /// The view's own layer (always there on iOS, set in commonInit on macOS).
    private var hostLayer: CALayer? { layer }
    private var hasFinished = false
    private var generation = 0

    /// Creates an empty view. Set ``media`` and call ``play()``.
    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    /// Creates the view from a storyboard or nib.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        #if canImport(AppKit) && !canImport(UIKit)
        // A layer-hosting view: the layer tree belongs to this class.
        layer = CALayer()
        wantsLayer = true
        #endif
    }

    // MARK: Playback

    /// Starts or resumes playback. Finished `.playOnce` media starts again
    /// from the first frame.
    public func play() {
        if hasFinished {
            hasFinished = false
            playback?.restart()
        }
        isPlaying = true
        updateRate()
    }

    /// Pauses on the current frame.
    public func pause() {
        isPlaying = false
        updateRate()
    }

    /// Pauses and goes back to the first frame.
    public func stop() {
        isPlaying = false
        hasFinished = false
        updateRate()
        playback?.restart()
    }

    private func mediaDidChange() {
        hasFinished = false
        tearDownPlayback()
        updatePlayback()
    }

    /// Creates the decoder while the view is in a window, and drops it otherwise.
    private func updatePlayback() {
        guard window != nil, let media, let hostLayer else {
            tearDownPlayback()
            return
        }
        guard playback == nil else { return }

        generation += 1
        let generation = self.generation
        let playback: MediaPlayback
        do {
            playback = try MediaPlayback(media: media, loops: loopMode == .loop) { [weak self] in
                DispatchQueue.main.async {
                    self?.playbackDidFinish(generation: generation)
                }
            }
        } catch {
            // The file went away or can not be decoded; the view stays empty,
            // just like a TLottieView whose frame fails to render.
            return
        }
        hostLayer.addSublayer(playback.layer)
        self.playback = playback
        hasFinished = false
        layoutPlaybackLayer()
        updateRate()
    }

    private func tearDownPlayback() {
        guard let playback else { return }
        playback.layer.removeFromSuperlayer()
        playback.invalidate()
        self.playback = nil
    }

    private func playbackDidFinish(generation: Int) {
        guard generation == self.generation, playback != nil else { return }
        isPlaying = false
        hasFinished = true
        updateRate()
        onFinish?()
    }

    private func updateRate() {
        playback?.setRate(isPlaying ? speed : 0)
    }

    // MARK: Layout

    /// Fills the view, turned upright for videos recorded in another orientation.
    private func layoutPlaybackLayer() {
        guard let videoLayer = playback?.layer, let media else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let turns = media.quarterTurns
        videoLayer.setAffineTransform(.identity)
        videoLayer.bounds = turns % 2 == 0
            ? CGRect(origin: .zero, size: bounds.size)
            : CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
        videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        #if canImport(UIKit)
        let clockwise: CGFloat = 1
        #else
        // AppKit layers have y pointing up, which flips the turn direction.
        let clockwise: CGFloat = -1
        #endif
        videoLayer.setAffineTransform(CGAffineTransform(rotationAngle: clockwise * CGFloat(turns) * .pi / 2))
        CATransaction.commit()
    }

    // MARK: Platform hooks

    #if canImport(UIKit)
    open override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        layoutPlaybackLayer()
    }
    #else
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePlayback()
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPlaybackLayer()
    }

    open override func layout() {
        super.layout()
        layoutPlaybackLayer()
    }
    #endif
}
