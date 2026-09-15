import AVFoundation
import CoreMedia
import UIKit

/// The one hardware-decoded video surface shared by the phone player, its Picture in Picture, and
/// the CarPlay window. Accepts JPEG frames (MJPEG feeds) and READY sample buffers (the H.264 feed
/// decoder and the screen-mirror decoder both hand over decoded frames), and can host an
/// `AVPlayerLayer` for HLS / MP4 feeds inside the same view.
///
/// Everything lands on `AVSampleBufferDisplayLayer` — never a `UIImage` on the hot path. The only
/// exception is an explicit fallback: if the layer reports `.failed` twice in a row (a car head
/// unit that rejects a codec, a corrupt stream) it switches to an image view so the screen shows
/// SOMETHING rather than staying black.
@MainActor
final class VideoCanvasView: UIView {
    override static var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }   // guaranteed by layerClass

    private var jpegFormat: CMVideoFormatDescription?
    private var jpegSize = (width: 0, height: 0)
    private var failures = 0
    private var useFallback = false
    private var playerLayer: AVPlayerLayer?
    private lazy var fallback: UIImageView = {
        let view = UIImageView(frame: bounds)
        view.contentMode = .scaleAspectFit
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isHidden = true
        addSubview(view)
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }

    func setGravity(_ gravity: AVLayerVideoGravity) {
        displayLayer.videoGravity = gravity
        playerLayer?.videoGravity = gravity
        fallback.contentMode = gravity == .resizeAspectFill ? .scaleAspectFill : .scaleAspectFit
    }

    func clear() {
        displayLayer.flushAndRemoveImage()
        jpegFormat = nil
        fallback.image = nil
    }

    // MARK: - AVPlayer (HLS / MP4)

    func attachPlayer(_ player: AVPlayer) {
        detachPlayer()
        let sublayer = AVPlayerLayer(player: player)
        sublayer.frame = bounds
        sublayer.videoGravity = displayLayer.videoGravity
        layer.addSublayer(sublayer)
        playerLayer = sublayer
    }

    func detachPlayer() {
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    // MARK: - JPEG frames

    func display(jpeg: Data) {
        if useFallback {
            // Explicit fallback only: decode off-main, paint on main.
            Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    RemoteImage.downsample(jpeg, maxPixel: 2000)
                }.value
                self?.fallback.image = image
            }
            return
        }
        guard let (width, height) = Self.jpegDimensions(jpeg) else { return }
        if jpegFormat == nil || jpegSize.width != width || jpegSize.height != height {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG,
                                           width: Int32(width), height: Int32(height),
                                           extensions: nil, formatDescriptionOut: &description)
            jpegFormat = description
            jpegSize = (width, height)
        }
        guard let format = jpegFormat, let buffer = Self.sampleBuffer(bytes: jpeg, format: format) else { return }
        enqueue(buffer)
    }

    // MARK: - Decoded sample buffers (H.264 feed decoder, screen mirror)

    func display(sampleBuffer: CMSampleBuffer) {
        Self.markDisplayImmediately(sampleBuffer)
        enqueue(sampleBuffer)
    }

    private func enqueue(_ buffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
            failures += 1
            if failures >= 2 {
                useFallback = true
                displayLayer.flushAndRemoveImage()
                fallback.isHidden = false
                return
            }
        }
        if displayLayer.isReadyForMoreMediaData { displayLayer.enqueue(buffer) }
    }

    // MARK: - Helpers (pure, thread-safe)

    /// Width/height from the JPEG's SOF marker, without decoding.
    nonisolated static func jpegDimensions(_ data: Data) -> (Int, Int)? {
        let bytes = [UInt8](data)
        var i = 2
        let n = bytes.count
        while i + 9 < n {
            guard bytes[i] == 0xFF else { i += 1; continue }
            let marker = bytes[i + 1]
            if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) { i += 2; continue }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                return (Int(bytes[i + 7]) << 8 | Int(bytes[i + 8]), Int(bytes[i + 5]) << 8 | Int(bytes[i + 6]))
            }
            i += 2 + length
        }
        return nil
    }

    /// Wraps compressed bytes in a sample buffer stamped "display now".
    nonisolated static func sampleBuffer(bytes: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = bytes.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block
        ) == noErr, let blockBuffer = block else { return nil }
        let copied = bytes.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sizes = [length]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sizes, sampleBufferOut: &sample
        ) == noErr, let out = sample else { return nil }
        markDisplayImmediately(out)
        return out
    }

    nonisolated static func markDisplayImmediately(_ buffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [CFMutableDictionary],
              let first = attachments.first else { return }
        CFDictionarySetValue(first,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
