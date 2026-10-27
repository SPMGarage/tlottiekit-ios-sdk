import AVFoundation
import CoreMedia

/// Feeds one `AVSampleBufferDisplayLayer` from a looping feeder.
///
/// The layer decodes video samples itself and shows each frame when its
/// timebase reaches the frame's timestamp, so there is no display link:
/// pausing or changing speed only changes the timebase rate. Feeding stops on
/// its own once the layer has a few frames queued.
///
/// The layer itself is main-thread only. Samples go through `renderer`, which
/// may be used from any thread: the layer's own video renderer on iOS 17 /
/// macOS 14 and later, the layer before that. The feeder, the finish timer
/// and the feeding flags are used on `queue` only.
final class MediaPlayback: @unchecked Sendable {
    /// Owned by this playback; the view adds it to its layer tree.
    let layer: AVSampleBufferDisplayLayer

    private let renderer: any AVQueuedSampleBufferRendering
    private let timebase: CMTimebase
    private let feeder: LoopingSampleFeeder
    private let onFinish: @Sendable () -> Void
    // Serial per playback, but backed by a shared pool of threads, so a grid
    // of players does not create a thread each.
    private let queue = DispatchQueue(
        label: "TLottieKitMedia.playback", qos: .userInitiated, target: .global(qos: .userInitiated)
    )
    private var finishTimer: DispatchSource?
    private var isFeeding = false
    private var isInvalidated = false
    private var observer: NSObjectProtocol?

    /// - Parameter onFinish: Called on a background queue when a pass ends
    ///   and `loops` is false.
    @MainActor
    init(media: TLottieMedia, loops: Bool, onFinish: @escaping @Sendable () -> Void) throws {
        feeder = LoopingSampleFeeder(source: try makeSampleSource(for: media), loops: loops)
        timebase = try Self.makeTimebase()
        self.onFinish = onFinish
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.controlTimebase = timebase
        self.layer = layer
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            renderer = layer.sampleBufferRenderer
        } else {
            renderer = layer
        }
        observer = observeDecoderInterruptions()
        queue.async { self.startFeeding() }
    }

    deinit {
        // Without invalidate(), the renderer would keep calling a feed block
        // whose playback is gone.
        renderer.stopRequestingMediaData()
        cancelFinishTimer()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Playback speed; 0 pauses on the current frame.
    func setRate(_ rate: Double) {
        CMTimebaseSetRate(timebase, rate: rate)
    }

    func setLoops(_ loops: Bool) {
        queue.async {
            self.feeder.loops = loops
            // A pass that already ended can continue into the next one.
            if loops, !self.isFeeding {
                self.cancelFinishTimer()
                self.startFeeding()
            }
        }
    }

    /// Goes back to the first frame, keeping the current rate.
    func restart() {
        queue.async { self.restartFromStart() }
    }

    /// Stops all work. The playback can not be used again.
    func invalidate() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        CMTimebaseSetRate(timebase, rate: 0)
        queue.async {
            self.isInvalidated = true
            self.stopFeeding()
            self.cancelFinishTimer()
            // Drops the queued frames now rather than when the layer goes away.
            self.renderer.flush()
        }
    }

    // MARK: Feeding (on `queue`)

    private func startFeeding() {
        guard !isFeeding, !isInvalidated else { return }
        isFeeding = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.feed()
        }
    }

    private func stopFeeding() {
        guard isFeeding else { return }
        renderer.stopRequestingMediaData()
        isFeeding = false
    }

    private func feed() {
        while isFeeding, renderer.isReadyForMoreMediaData, let sample = nextSample() {
            renderer.enqueue(sample)
        }
    }

    /// The next sample, or nil after stopping because playback ended or failed.
    private func nextSample() -> CMSampleBuffer? {
        let sample: CMSampleBuffer?
        do {
            sample = try feeder.next()
        } catch {
            // An unreadable file keeps showing its last good frame.
            stopFeeding()
            return nil
        }
        guard let sample else {
            stopFeeding()
            scheduleFinish(at: feeder.passEnd)
            return nil
        }
        return sample
    }

    private func restartFromStart() {
        guard !isInvalidated else { return }
        stopFeeding()
        cancelFinishTimer()
        renderer.flush()
        feeder.reset()
        CMTimebaseSetTime(timebase, time: .zero)
        startFeeding()
    }

    // MARK: End of a single pass (on `queue`)

    /// Fires when the timebase reaches `time`, which follows pauses and
    /// speed changes on its own.
    private func scheduleFinish(at time: CMTime) {
        cancelFinishTimer()
        guard let timer = DispatchSource.makeTimerSource(queue: queue) as? DispatchSource else { return }
        timer.setEventHandler { [weak self] in
            self?.finishTimerFired()
        }
        CMTimebaseAddTimerDispatchSource(timebase, timerSource: timer)
        CMTimebaseSetTimerDispatchSourceNextFireTime(timebase, timerSource: timer, fireTime: time, flags: 0)
        timer.resume()
        finishTimer = timer
    }

    private func finishTimerFired() {
        cancelFinishTimer()
        guard !isInvalidated else { return }
        onFinish()
    }

    private func cancelFinishTimer() {
        guard let timer = finishTimer else { return }
        CMTimebaseRemoveTimerDispatchSource(timebase, timerSource: timer)
        timer.cancel()
        finishTimer = nil
    }

    // MARK: Setup

    /// iOS stops hardware decoding while the app is in the background; the
    /// renderer then needs a flush and fresh samples before it shows frames.
    @MainActor
    private func observeDecoderInterruptions() -> NSObjectProtocol? {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            return NotificationCenter.default.addObserver(
                forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                object: layer.sampleBufferRenderer,
                queue: nil
            ) { [weak self] _ in
                guard let self, let videoRenderer = self.renderer as? AVSampleBufferVideoRenderer,
                      videoRenderer.requiresFlushToResumeDecoding
                else { return }
                self.restart()
            }
        } else if #available(iOS 14.0, tvOS 14.0, *) {
            return NotificationCenter.default.addObserver(
                forName: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange,
                object: layer,
                queue: .main
            ) { [weak self] _ in
                // Delivered on the main queue, where the layer may be read.
                MainActor.assumeIsolated {
                    if self?.layer.requiresFlushToResumeDecoding == true {
                        self?.restart()
                    }
                }
            }
        }
        return nil
    }

    private static func makeTimebase() throws -> CMTimebase {
        var timebase: CMTimebase?
        let status: OSStatus
        if #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) {
            status = CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase
            )
        } else {
            status = CMTimebaseCreateWithMasterClock(
                allocator: kCFAllocatorDefault, masterClock: CMClockGetHostTimeClock(), timebaseOut: &timebase
            )
        }
        guard status == noErr, let timebase else {
            throw TLottieMediaError.unreadable
        }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0)
        return timebase
    }
}
