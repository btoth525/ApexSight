import AVFoundation
import QuartzCore

/// One decoded-frame tap per live `AVPlayer`. Owns the single `AVPlayerItemVideoOutput`,
/// follows the player across HLS reconnects, and publishes the latest NV12 buffer for any
/// number of dewarp renderers to read.
///
/// WHY ONE SHARED SOURCE: attaching several `AVPlayerItemVideoOutput`s to the same player
/// item starves all but one on real hardware — the quad view's four panes each had their
/// own output, so three froze on device (the sim's software decoder masked it). All panes
/// of a stream now read from this single source, and the single view uses one too.
///
/// The pull runs on a `CADisplayLink` (independent of any MTKView), stores the newest buffer
/// under a lock, and re-attaches the output if frames stop while the player is still playing —
/// so a stalled tap self-heals instead of freezing on the last frame.
final class FisheyeFrameSource: NSObject, ObservableObject, AVPlayerItemOutputPullDelegate {
    /// The HLS model rebuilds its AVPlayer on every reconnect; the owner updates this and the
    /// next tick re-attaches the output to the new item.
    weak var player: AVPlayer?

    private let output: AVPlayerItemVideoOutput
    private weak var attachedItem: AVPlayerItem?
    private var displayLink: CADisplayLink?
    private var started = false

    private var lock = os_unfair_lock_s()
    private var buffer: CVPixelBuffer?
    private var lastFreshAt: CFTimeInterval = 0
    private var lastKickAt: CFTimeInterval = 0

    /// The newest decoded frame, or nil until the first arrives. Thread-safe.
    var latest: CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return buffer
    }

    init(player: AVPlayer) {
        self.player = player
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        super.init()
        output.setDelegate(self, queue: .main)
    }

    /// Begin pulling frames. Idempotent — quad panes all share one source and each calls this.
    func start() {
        guard !started else { return }
        started = true
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stop pulling and detach. The CADisplayLink retains its target, so this MUST be called
    /// (on the owning view's disappear) or the source leaks.
    func stop() {
        started = false
        displayLink?.invalidate()
        displayLink = nil
        if let item = attachedItem, item.outputs.contains(output) { item.remove(output) }
        attachedItem = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        attachIfNeeded()
        // The host time of the NEXT frame is the correct query time for a display-synced pull.
        let hostTime = link.timestamp + link.duration
        let itemTime = output.itemTime(forHostTime: hostTime)
        let now = CACurrentMediaTime()

        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let fresh = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            os_unfair_lock_lock(&lock)
            buffer = fresh
            os_unfair_lock_unlock(&lock)
            lastFreshAt = now
        } else if lastFreshAt > 0, now - lastFreshAt > 0.7, now - lastKickAt > 1.0 {
            // Frames stopped while the player still reports playing → the output starved.
            // Re-add it (a fresh attach forces the pipeline to service it again) rather than
            // sitting frozen on the last frame.
            lastKickAt = now
            if player?.timeControlStatus == .playing, let item = attachedItem {
                if item.outputs.contains(output) { item.remove(output) }
                item.add(output)
                output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            }
        }

        #if DEBUG && targetEnvironment(simulator)
        // SIM TEST HARNESS: the simulator's AVPlayerItemVideoOutput tap never delivers a pixel
        // buffer for these HLS streams, so the dewarp can't be exercised on the sim at all — which
        // is exactly why fisheye regressions (black, freeze) shipped unseen. When no real frame has
        // arrived, publish a synthetic moving test frame so the Metal render path (and any UI
        // layered over it) actually runs and can be verified here. Compiled out of Release/device.
        // Deliberately delayed a few seconds so the "no frame yet" startup state (snapshot showing
        // through the transparent dewarp) is observable before synthetic content takes over.
        if harnessStartAt == 0 { harnessStartAt = now }
        if lastFreshAt == 0, now - harnessStartAt > 3 { publishSyntheticFrame(now) }
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    private var harnessStartAt: CFTimeInterval = 0
    private var syntheticPool: CVPixelBufferPool?
    /// Fills `buffer` with a moving grayscale band pattern (visibly live so liveness is obvious;
    /// neutral chroma so the dewarp geometry is legible). Sim-debug only.
    private func publishSyntheticFrame(_ now: CFTimeInterval) {
        let w = 720, h = 720
        if syntheticPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &syntheticPool)
        }
        guard let pool = syntheticPool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let phase = Int(now * 90)
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let y = yBase.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h { memset(y + row * stride, Int32((row + phase) & 0xFF), w) }
        }
        if let cbcr = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            memset(cbcr, 128, stride * (h / 2))  // neutral chroma → grayscale
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        os_unfair_lock_lock(&lock)
        buffer = pb
        os_unfair_lock_unlock(&lock)
    }
    #endif

    private func attachIfNeeded() {
        guard let item = player?.currentItem, item !== attachedItem else { return }
        if let old = attachedItem, old.outputs.contains(output) { old.remove(output) }
        if !item.outputs.contains(output) { item.add(output) }
        attachedItem = item
        lastFreshAt = 0  // reset the starvation watchdog for the new item
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
    }

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {}

    deinit { displayLink?.invalidate() }
}
