import QuartzCore

#if canImport(UIKit)
import UIKit
/// The view TLottieKit's players build on: `UIView` on iOS.
public typealias TLottiePlatformView = UIView
#elseif canImport(AppKit)
import AppKit
/// The view TLottieKit's players build on: `NSView` on macOS.
public typealias TLottiePlatformView = NSView
#endif

/// Plays a ``TLottieAnimation`` (UIKit on iOS, AppKit on macOS).
///
/// Frames are rendered off the main thread at the view's pixel size and shown
/// aspect-fit. While the view is not in a window it shows the current frame
/// but does not advance, so offscreen animations cost nothing.
///
/// ```swift
/// let view = TLottieView()
/// view.animation = try TLottieAnimation(named: "sticker")
/// view.loopMode = .playOnce
/// view.onFinish = { print("done") }
/// view.play()
/// ```
///
/// In SwiftUI, use ``TLottiePlayer`` instead.
@MainActor
open class TLottieView: TLottiePlatformView {
    /// The animation to show. Setting a new one shows its first frame;
    /// call `play()` to start it.
    public var animation: TLottieAnimation? {
        didSet {
            guard animation !== oldValue else { return }
            animationDidChange()
        }
    }

    /// What happens at the last frame. The default is ``TLottieLoopMode/loop``.
    public var loopMode: TLottieLoopMode = .loop

    /// Playback speed multiplier. 0 freezes the current frame.
    public var speed: Double = 1 {
        didSet {
            if speed < 0 { speed = 0 }
            restartDriverIfRunning()
        }
    }

    /// Largest side of a rendered frame in pixels. Bigger views are upscaled.
    public var maximumRenderDimension: Int = 2048 {
        didSet { requestRender() }
    }

    /// Called on the main thread when a `.playOnce` animation reaches its last frame.
    public var onFinish: (() -> Void)?

    /// Whether playback is running. It turns false when a ``TLottieLoopMode/playOnce``
    /// animation reaches its end.
    public private(set) var isPlaying = false

    /// The frame currently shown (or about to be shown).
    public var currentFrame: Int { clock.frame }

    private var clock = PlaybackClock()
    private var lastTickTime: CFTimeInterval?
    private var generation = 0
    private var requestedKey: RenderKey?
    private var renderInFlight = false
    private var displayedImage: CGImage?
    private let renderQueue = DispatchQueue(label: "TLottieKit.TLottieView.render", qos: .userInitiated)

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    #else
    private var timer: Timer?
    #endif

    /// Creates an empty view. Set ``animation`` and call ``play()``.
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
        #if canImport(UIKit)
        layer.contentsGravity = .resizeAspect
        #else
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsGravity = .resizeAspect
        #endif
    }

    // MARK: Playback

    /// Starts or resumes playback. A finished ``TLottieLoopMode/playOnce``
    /// animation starts again from the first frame.
    public func play() {
        if let animation, loopMode == .playOnce, clock.isAtEnd(frameCount: animation.frameCount) {
            clock.reset()
            requestRender()
        }
        isPlaying = true
        lastTickTime = nil
        updateDriver()
    }

    /// Pauses on the current frame.
    public func pause() {
        isPlaying = false
        updateDriver()
    }

    /// Pauses and goes back to the first frame.
    public func stop() {
        isPlaying = false
        clock.reset()
        updateDriver()
        requestRender()
    }

    /// Shows `frame`, clamped to `0 ..< frameCount`, without starting or
    /// stopping playback.
    public func seek(toFrame frame: Int) {
        guard let animation else { return }
        clock.seek(toFrame: frame, frameCount: animation.frameCount)
        requestRender()
    }

    private func animationDidChange() {
        generation += 1
        requestedKey = nil
        clock.reset()
        lastTickTime = nil
        show(nil)
        updateDriver()
        requestRender()
    }

    fileprivate func tick() {
        guard let animation else { return }
        let now = CACurrentMediaTime()
        defer { lastTickTime = now }
        // The first tick only sets the time base.
        guard let previous = lastTickTime else { return }

        let finished = clock.advance(
            seconds: now - previous,
            framesPerSecond: animation.frameRate * speed,
            frameCount: animation.frameCount,
            loopMode: loopMode
        )
        requestRender()
        if finished {
            isPlaying = false
            updateDriver()
            onFinish?()
        }
    }

    // MARK: Frame driver

    private var shouldRunDriver: Bool {
        guard isPlaying, window != nil, speed > 0, let animation else { return false }
        return animation.frameCount > 1 && animation.frameRate > 0
    }

    private func updateDriver() {
        if shouldRunDriver {
            startDriver()
        } else {
            stopDriver()
            lastTickTime = nil
        }
    }

    private func restartDriverIfRunning() {
        guard isDriverRunning else { return }
        stopDriver()
        updateDriver()
    }

    /// Frames per second the driver should tick at, capped to 120 Hz.
    private var tickRate: Double {
        guard let animation else { return 60 }
        return min(max(animation.frameRate * speed, 1), 120)
    }

    #if canImport(UIKit)
    private var isDriverRunning: Bool { displayLink != nil }

    private func startDriver() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(view: self), selector: #selector(DisplayLinkTarget.tick(_:)))
        let rate = Float(tickRate)
        if #available(iOS 15.0, tvOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
        } else {
            link.preferredFramesPerSecond = Int(rate.rounded())
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDriver() {
        displayLink?.invalidate()
        displayLink = nil
    }
    #else
    private var isDriverRunning: Bool { timer != nil }

    private func startDriver() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / tickRate, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            // Scheduled on the main run loop, so this is the main thread.
            MainActor.assumeIsolated {
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopDriver() {
        timer?.invalidate()
        timer = nil
    }
    #endif

    // MARK: Rendering

    private func requestRender() {
        guard let animation, let size = renderPixelSize(for: animation) else { return }
        let key = RenderKey(generation: generation, frame: clock.frame, width: size.width, height: size.height)
        // One render at a time; finishRender asks again for whatever is newest.
        guard key != requestedKey, !renderInFlight else { return }
        renderInFlight = true
        requestedKey = key

        renderQueue.async {
            let rendered = RenderedFrame(
                image: try? animation.makeImage(frame: Double(key.frame), width: key.width, height: key.height)
            )
            DispatchQueue.main.async {
                self.finishRender(rendered, for: key)
            }
        }
    }

    private func finishRender(_ rendered: RenderedFrame, for key: RenderKey) {
        renderInFlight = false
        if key.generation == generation, let image = rendered.image {
            show(image)
        }
        requestRender()
    }

    private func renderPixelSize(for animation: TLottieAnimation) -> (width: Int, height: Int)? {
        let bounds = self.bounds.size
        let natural = animation.size
        guard bounds.width > 0, bounds.height > 0, natural.width > 0, natural.height > 0 else {
            return nil
        }
        let fit = min(bounds.width / natural.width, bounds.height / natural.height)
        var width = natural.width * fit * displayScale
        var height = natural.height * fit * displayScale
        let largest = max(width, height)
        let cap = CGFloat(max(1, maximumRenderDimension))
        if largest > cap {
            width *= cap / largest
            height *= cap / largest
        }
        return (max(1, Int(width.rounded())), max(1, Int(height.rounded())))
    }

    private func show(_ image: CGImage?) {
        displayedImage = image
        #if canImport(UIKit)
        layer.contents = image
        #else
        needsDisplay = true
        #endif
    }

    // MARK: Platform hooks

    #if canImport(UIKit)
    private var displayScale: CGFloat {
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : 2
    }

    open override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDriver()
        requestRender()
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        requestRender()
    }
    #else
    private var displayScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    open override var wantsUpdateLayer: Bool { true }

    open override func updateLayer() {
        layer?.contents = displayedImage
        layer?.contentsGravity = .resizeAspect
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDriver()
        requestRender()
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestRender()
    }

    open override func layout() {
        super.layout()
        requestRender()
    }
    #endif
}

private struct RenderKey: Equatable {
    let generation: Int
    let frame: Int
    let width: Int
    let height: Int
}

/// CGImage is immutable, so handing it from the render queue to the main
/// thread is safe.
private struct RenderedFrame: @unchecked Sendable {
    let image: CGImage?
}

#if canImport(UIKit)
/// CADisplayLink retains its target; this weak hop keeps it from retaining the view.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var view: TLottieView?

    init(view: TLottieView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.tick()
    }
}
#endif
