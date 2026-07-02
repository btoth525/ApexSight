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
    }

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
