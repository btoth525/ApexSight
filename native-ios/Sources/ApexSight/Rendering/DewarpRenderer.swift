import AVFoundation
import Metal
import MetalKit

/// Dewarps the latest NV12 frame from a shared `FisheyeFrameSource` with a single
/// fragment-shader pass: wraps the Y + CbCr planes as Metal textures zero-copy
/// (`CVMetalTextureCache`) and draws a full-screen triangle at display-link rate.
///
/// The renderer owns NO video output — several renderers (the four quad panes) share one
/// `FisheyeFrameSource`, because multiple outputs on one player item starve on device.
final class DewarpRenderer: NSObject, MTKViewDelegate {
    /// Written by SwiftUI gestures/calibration on the main thread, read here on the
    /// display-link thread. Plain floats — one possible torn read per frame is invisible.
    var uniforms = DewarpUniformsData()

    /// The frame tap this renderer samples. Set by the host view; shared across quad panes.
    weak var frameSource: FisheyeFrameSource?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    /// Last frame we drew — re-rendered between source updates so pan/tilt/zoom gestures
    /// track at full frame rate even when the camera itself is low-fps.
    private var lastPixelBuffer: CVPixelBuffer?

    override init() {
        // Force-unwrap is the norm for MTLCreateSystemDefaultDevice on real devices/sim;
        // a nil device means Metal is unavailable, in which case nothing here can run.
        self.device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()
        super.init()

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        guard let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "dewarpVertex"),
              let fragmentFn = library.makeFunction(name: "dewarpFragment") else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if let fresh = frameSource?.latest { lastPixelBuffer = fresh }

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
