import AVFoundation
import Metal
import MetalKit

/// Pulls decoded NV12 frames off a live `AVPlayer` via `AVPlayerItemVideoOutput`,
/// wraps the Y + CbCr planes as Metal textures zero-copy (`CVMetalTextureCache`),
/// and dewarps them with a single fragment-shader pass at display-link rate.
///
/// The HLS model rebuilds its `AVPlayerItem` on every reconnect, so the output is
/// re-attached whenever the player's current item changes (checked per draw).
///
/// GOTCHA (hit live on the sim): an output added to an item that is ALREADY playing
/// can starve — `hasNewPixelBuffer` stays false forever and the view renders black.
/// `requestNotificationOfMediaDataChange` marks the output as awaiting data, which
/// kicks the pipeline into servicing it; a per-draw watchdog re-kicks if frames stop
/// arriving while the player still claims to be playing.
final class DewarpRenderer: NSObject, MTKViewDelegate, AVPlayerItemOutputPullDelegate {
    /// Written by SwiftUI gestures/calibration on the main thread, read here on the
    /// display-link thread. Plain floats — one possible torn read per frame is invisible.
    var uniforms = DewarpUniformsData()

    /// The HLS model builds a NEW AVPlayer on every reconnect — the host view swaps
    /// this reference when that happens and the next draw re-attaches the output.
    weak var player: AVPlayer?
    private var attachedItem: AVPlayerItem?
    private let output: AVPlayerItemVideoOutput
    private var pendingAttach = false

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    /// Kept so the view keeps rendering (and gestures stay responsive) between
    /// new frames — the shader re-runs on the latest buffer as uniforms change.
    private var lastPixelBuffer: CVPixelBuffer?
    /// Starvation watchdog: when the last fresh frame is older than this while the
    /// player reports `.playing`, the output gets re-kicked (see class note).
    private var lastFreshFrameAt: CFTimeInterval = 0
    private var lastKickAt: CFTimeInterval = 0

    init?(player: AVPlayer) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        self.player = player
        self.commandQueue = device.makeCommandQueue()

        // NV12 video-range, Metal-compatible — matches the decoder's native output so
        // the copy out of AVFoundation is free, and matches the shader's YUV math.
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])

        super.init()

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        guard let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "dewarpVertex"),
              let fragmentFn = library.makeFunction(name: "dewarpFragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        if pipeline == nil { return nil }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        attachOutputIfNeeded()

        // Prefer a fresh frame; otherwise re-render the last one so pan/tilt/zoom
        // gestures track at full frame rate even when the source is a low-fps camera.
        let now = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: now)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let fresh = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            lastPixelBuffer = fresh
            lastFreshFrameAt = now
        } else if now - lastFreshFrameAt > 2, now - lastKickAt > 2 {
            // No frames for 2s straight — if the player thinks it's playing, the output
            // starved (added mid-playback). Re-request media-data notification to kick
            // the pipeline back into servicing us.
            lastKickAt = now
            let output = self.output
            DispatchQueue.main.async { [weak self] in
                guard let self, self.player?.timeControlStatus == .playing else { return }
                output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            }
        }
        guard let buffer = lastPixelBuffer,
              let pipeline,
              let commandQueue,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let yTex = makeTexture(buffer, plane: 0, format: .r8Unorm),
              let cbcrTex = makeTexture(buffer, plane: 1, format: .rg8Unorm),
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        var u = uniforms
        u.texAspect = Float(CVPixelBufferGetWidth(buffer)) / Float(max(CVPixelBufferGetHeight(buffer), 1))
        u.viewAspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(cbcrTex, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<DewarpUniformsData>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Follow the player across HLS reconnects: whenever `currentItem` changes, move
    /// the video output onto the new item. `add(_:)` is marshalled to the main thread
    /// (AVPlayerItem outputs aren't documented thread-safe to mutate off it), with a
    /// `pendingAttach` latch so at most one hop is in flight.
    private func attachOutputIfNeeded() {
        guard let item = player?.currentItem, item !== attachedItem, !pendingAttach else { return }
        pendingAttach = true
        let output = self.output
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.pendingAttach = false }
            guard let current = self.player?.currentItem else { return }
            if let old = self.attachedItem, old.outputs.contains(output) {
                old.remove(output)
            }
            if !current.outputs.contains(output) {
                current.add(output)
            }
            self.attachedItem = current
            // Kick the pipeline: without this, an output attached to an already-playing
            // item may never receive buffers (verified live — black view until nudged).
            output.setDelegate(self, queue: .main)
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        }
    }

    /// AVPlayerItemOutputPullDelegate — the draw loop polls, so nothing to do here;
    /// registering the delegate is what marks the output as actively serviced.
    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {}

    /// Zero-copy: wraps one plane of the NV12 pixel buffer as a Metal texture —
    /// the GPU samples the same memory the video decoder wrote into.
    private func makeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> MTLTexture? {
        guard let textureCache else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
