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
    /// Reports that the stream ended or couldn't connect (offline camera, HTTP error, timeout,
    /// or a mid-stream drop) so callers can surface a retry instead of sitting on "Connecting…".
    /// Never fired for our own suspend()/stop() cancellations.
    var onError: (() -> Void)? = nil

    func makeUIView(context: Context) -> MJPEGUIView {
        let view = MJPEGUIView()
        view.imageView.contentMode = contentMode
        view.onFirstFrame = onFirstFrame
        view.onError = onError
        view.start(request: client.authedRequest(for: url))
        return view
    }

    func updateUIView(_ uiView: MJPEGUIView, context: Context) {
        uiView.imageView.contentMode = contentMode
        // Refresh the callbacks — SwiftUI hands fresh closures on each update, and the ones
        // captured at makeUIView would otherwise go stale (e.g. capturing an old fill mode).
        uiView.onFirstFrame = onFirstFrame
        uiView.onError = onError
    }

    static func dismantleUIView(_ uiView: MJPEGUIView, coordinator: ()) {
        uiView.stop()
    }
}

/// Owns the stream: the `URLSession`, its data task, the multipart byte buffer and the
/// frame-drop gate, plus the lifecycle policy (suspend on background, re-open on foreground,
/// stop on dismantle).
///
/// Concurrency: everything in here is main-actor, including the `URLSessionDataDelegate`
/// callbacks — see the `@preconcurrency` extension below for why that is honest and not a
/// hack. The one thing that must NOT run on main, the JPEG decode, is hoisted onto
/// `decodeQueue` and only hops back to apply the finished `UIImage`.
final class MJPEGUIView: UIView {
    let imageView = UIImageView()
    var onFirstFrame: (() -> Void)?
    var onError: (() -> Void)?
    /// True while a suspend()/stop() is tearing the task down, so the resulting
    /// `didCompleteWithError(NSURLErrorCancelled)` isn't misreported as a stream failure.
    private var isTearingDown = false
    /// Fire `onError` at most once per connection attempt (a rejected response also produces a
    /// follow-up `didCompleteWithError`, which would otherwise report twice).
    private var hasReportedError = false

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var hasDeliveredFrame = false
    private var isDisplayPending = false
    /// Kept so we can re-open the stream after returning from background.
    private var currentRequest: URLRequest?
    // Removed from a nonisolated deinit; NotificationCenter.removeObserver is thread-safe.
    private nonisolated(unsafe) var lifecycleObservers: [NSObjectProtocol] = []
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
        isTearingDown = false
        hasReportedError = false
        // Reset per-connection so `onFirstFrame` fires again after a reconnect (background→
        // foreground, or a recovered drop). Callers use that callback to clear an "offline"
        // overlay — without the reset it would stay pinned over a now-live picture.
        hasDeliveredFrame = false
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // Deliberately unbounded — the one exception to the "every Frigate session has a
        // wall-clock cap" rule (see BoundedSession). A live multipart stream is SUPPOSED to
        // stay open for as long as the tile is on screen; a resource cap would just kill a
        // healthy picture every N minutes. What bounds it instead is the lifecycle below:
        // `suspend()` on background and `stop()` on dismantle cancel the task and invalidate
        // the session, closing the socket so Frigate stops pushing frames. The response is
        // never abandoned — every byte is read until we cancel.
        config.timeoutIntervalForResource = .infinity
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Deliver delegate callbacks on main so `buffer`/`isDisplayPending` are only ever
        // touched there — including from suspend()/stop() — with no cross-thread data race.
        // The expensive part (JPEG decode) still runs off-main on `decodeQueue`; only the
        // cheap multipart byte-scan happens on main.
        //
        // ⚠️ `.main` here is load-bearing for the `@preconcurrency URLSessionDataDelegate`
        // conformance at the bottom of this file: that conformance asserts main-actor
        // isolation on entry to every delegate method. Change this queue and those methods
        // trap at runtime instead of failing to compile — split the networking into a
        // nonisolated object first.
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
            MainActor.assumeIsolated { self?.suspend() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openConnection() }
        })
    }

    /// Tear down the live connection but keep `currentRequest` so it can be re-opened.
    private func suspend() {
        isTearingDown = true
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

    /// Surface a stream failure to the caller exactly once per connection attempt.
    private func reportError() {
        guard !isTearingDown, !hasReportedError else { return }
        hasReportedError = true
        onError?()
    }

    /// Decode a JPEG frame to a fully-decoded UIImage on the calling (background) queue.
    private nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

/// `URLSessionDataDelegate` is a nonisolated protocol, and a `UIView` subclass is `@MainActor`, so
/// under `-strict-concurrency=complete` a plain conformance reports "crosses into main actor-isolated
/// code". That diagnostic is accepted here, and here is why the obvious fixes are wrong:
/// - An ISOLATED conformance (`@MainActor URLSessionDataDelegate`) is impossible — `URLSessionDelegate`
///   inherits `Sendable`, and the compiler rejects a main-actor-isolated conformance for it.
/// - `@preconcurrency` on the conformance is a no-op in the Swift 5 language mode (it warns as such).
/// - Splitting the networking into a `@unchecked Sendable` connection object would move a byte-scan
///   that costs ~0.1% of one core per camera, at the price of less compiler verification.
/// What actually makes this correct is `openConnection()` creating the session with
/// `delegateQueue: .main`: every callback below runs on the main thread, so touching `buffer`,
/// `isDisplayPending`, `isTearingDown` and `hasReportedError` here is genuine main-actor access.
/// If that queue ever changes, this reasoning no longer holds — split the networking out first.
extension MJPEGUIView: URLSessionDataDelegate {
    /// Reject a non-2xx response (offline camera → 502/504 from the proxy, 401 on a stale token)
    /// before it's mistaken for stream data — surface it as an error so a retry can appear.
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            reportError()
            return
        }
        completionHandler(.allow)
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
            // Back to main to apply it. `DispatchQueue.main` is FIFO, so a frame and a trailing
            // error land in the order they were produced; `assumeIsolated` is what lets the
            // compiler see that this block really is main-actor state access.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
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
    }

    /// The stream ended: either it never connected (offline camera, DNS/TLS failure, timeout)
    /// or a live connection dropped. A healthy multipart MJPEG stream never completes on its own,
    /// so any non-cancel completion is a real failure worth surfacing.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Our own suspend()/stop() cancellations aren't failures.
        if isTearingDown { return }
        if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
        reportError()
    }
}
