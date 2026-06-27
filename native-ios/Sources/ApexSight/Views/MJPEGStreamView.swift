import ImageIO
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
    /// Kept so we can re-open the stream after returning from background.
    private var currentRequest: URLRequest?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// JPEG frames decode here, off the main thread — decoding once per delivered frame
    /// per camera on main is what janks a multi-camera wall on the MJPEG fallback path.
    private let decodeQueue = DispatchQueue(label: "com.brandontoth.apexsight.mjpeg.decode", qos: .userInitiated)

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

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start(request: URLRequest) {
        currentRequest = request
        observeLifecycle()
        openConnection()
    }

    /// Open (or re-open) the MJPEG connection for the stored request.
    private func openConnection() {
        guard let request = currentRequest, task == nil else { return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = .infinity
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Deliver delegate callbacks on main so `buffer`/`isDisplayPending` are only ever
        // touched there — including from suspend()/stop() — with no cross-thread data race.
        // The expensive part (JPEG decode) still runs off-main on `decodeQueue`; only the
        // cheap multipart byte-scan happens on main.
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    /// Pause networking when the app backgrounds — keep the last frame on screen and the
    /// request so we can resume instantly on return. Without this the data task keeps
    /// pulling frames in the background (battery/data drain) on the HLS→MJPEG fallback path.
    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.suspend()
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.openConnection()
        })
    }

    /// Tear down the live connection but keep `currentRequest` so it can be re-opened.
    private func suspend() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer.removeAll(keepingCapacity: true)
        isDisplayPending = false
    }

    func stop() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
        currentRequest = nil
        suspend()
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
        // Drop frame if previous is still being decoded/rendered.
        guard !isDisplayPending else { return }
        isDisplayPending = true

        decodeQueue.async { [weak self] in
            guard let self else { return }
            // Force the JPEG decode here (off main) via ImageIO; UIImage(data:) alone would
            // defer the decode to the main thread at display time.
            let image = Self.decode(frameData)
            DispatchQueue.main.async {
                defer { self.isDisplayPending = false }
                guard let image else { return }
                self.imageView.image = image
                if !self.hasDeliveredFrame {
                    self.hasDeliveredFrame = true
                    self.onFirstFrame?()
                }
            }
        }
    }

    /// Decode a JPEG frame to a fully-decoded UIImage on the calling (background) queue.
    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}
