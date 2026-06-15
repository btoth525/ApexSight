import SwiftUI
import UIKit

/// Native live MJPEG player for Frigate's `/api/<camera>` stream.
///
/// Stock Frigate exposes NO live HLS, and MSE/WebRTC are unreliable inside an
/// iPhone WKWebView or over remote HTTPS without extra ports. The MJPEG detect
/// stream (multipart/x-mixed-replace) works through any reverse proxy over HTTPS
/// and is cheap enough to run many simultaneously, so it powers the auto-playing
/// camera grid and the default full-screen live view.
struct MJPEGStreamView: UIViewRepresentable {
    let url: URL
    let client: FrigateClient
    /// `.scaleAspectFit` shows the whole frame (no sides cut off); `.scaleAspectFill` fills the box.
    var contentMode: UIView.ContentMode = .scaleAspectFit
    /// Reports the first decoded frame so callers can cross-fade away a placeholder.
    var onFirstFrame: (() -> Void)? = nil

    func makeUIView(context: Context) -> MJPEGUIView {
        let view = MJPEGUIView()
        view.imageView.contentMode = contentMode
        view.onFirstFrame = onFirstFrame
        view.start(request: client.authedRequest(for: url))
        return view
    }

    func updateUIView(_ uiView: MJPEGUIView, context: Context) {
        uiView.imageView.contentMode = contentMode
    }

    static func dismantleUIView(_ uiView: MJPEGUIView, coordinator: ()) {
        uiView.stop()
    }
}

final class MJPEGUIView: UIView, URLSessionDataDelegate {
    let imageView = UIImageView()
    var onFirstFrame: (() -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var hasDeliveredFrame = false
    private var isDisplayPending = false

    // JPEG start-of-image / end-of-image markers.
    private static let soi = Data([0xFF, 0xD8])
    private static let eoi = Data([0xFF, 0xD9])

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.backgroundColor = .black
        imageView.clipsToBounds = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start(request: URLRequest) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = .infinity
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer.removeAll()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)

        // Extract all complete frames, keep only the last (drop intermediate frames).
        var latestFrameData: Data?
        while let soiRange = buffer.range(of: Self.soi),
              let eoiRange = buffer.range(of: Self.eoi, in: soiRange.upperBound..<buffer.endIndex) {
            latestFrameData = buffer.subdata(in: soiRange.lowerBound..<eoiRange.upperBound)
            buffer.removeSubrange(buffer.startIndex..<eoiRange.upperBound)
        }

        // Guard against unbounded growth if frames never complete.
        if buffer.count > 2_000_000 { buffer.removeAll(keepingCapacity: true) }

        guard let frameData = latestFrameData else { return }
        // Drop frame if previous is still being rendered.
        guard !isDisplayPending else { return }
        isDisplayPending = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isDisplayPending = false }
            guard let image = UIImage(data: frameData) else { return }
            self.imageView.image = image
            if !self.hasDeliveredFrame {
                self.hasDeliveredFrame = true
                self.onFirstFrame?()
            }
        }
    }
}
