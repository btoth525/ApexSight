import Foundation

/// Byte-level client for the two raw feed kinds: MJPEG (`multipart/x-mixed-replace`) and raw
/// H.264 Annex-B over HTTP. It only READS; framing is minimal. MJPEG is cut into whole JPEGs
/// here; H.264 bytes are forwarded as they arrive — `VideoDecoderAnnexBAdaptor` (Transcoding)
/// does the NAL splitting, SPS/PPS tracking and VideoToolbox decode.
///
/// Delegate callbacks arrive on a private serial queue. `CarVideoSession` hops to the main actor.
protocol CameraStreamClientDelegate: AnyObject {
    func cameraStream(_ client: CameraStreamClient, jpeg: Data)
    func cameraStream(_ client: CameraStreamClient, h264 annexB: Data)
    func cameraStream(_ client: CameraStreamClient, ended error: Error?)
}

final class CameraStreamClient: NSObject, @unchecked Sendable {
    enum Codec { case mjpeg, h264 }

    weak var delegate: CameraStreamClientDelegate?
    private(set) var codec: Codec = .mjpeg

    private let queue = DispatchQueue(label: "com.brandontoth.apexsight.carvideo.stream", qos: .userInteractive)
    /// Session, task and buffer are touched only on `queue` (the session's delegate queue).
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var isStopping = false

    private static let soi = Data([0xFF, 0xD8])
    private static let eoi = Data([0xFF, 0xD9])
    /// Cap the scratch buffer so a stream that never completes a frame can't grow unbounded.
    private static let maxBuffer = 4 * 1024 * 1024

    func start(request: URLRequest, codec: Codec) {
        queue.async { [self] in
            stopLocked()
            self.codec = codec
            buffer.removeAll(keepingCapacity: true)
            isStopping = false
            // Ephemeral (no cache, no cookies of its own), 8 s to first byte, and — the one deliberate
            // exception to the app's "every session has a wall-clock cap" rule, same as the MJPEG
            // live tile — no resource cap: a live stream is SUPPOSED to stay open until we cancel it.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = .infinity
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let operationQueue = OperationQueue()
            operationQueue.underlyingQueue = queue
            operationQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: operationQueue)
            self.session = session
            var request = request
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func stop() {
        queue.async { [self] in stopLocked() }
    }

    private func stopLocked() {
        isStopping = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Parsing (on `queue`)

    private func drainJPEG() {
        while true {
            guard let soi = buffer.range(of: Self.soi) else {
                buffer.removeAll(keepingCapacity: true)
                return
            }
            guard let eoi = buffer.range(of: Self.eoi, in: soi.upperBound..<buffer.endIndex) else {
                if soi.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<soi.lowerBound) }
                if buffer.count > Self.maxBuffer { buffer.removeAll(keepingCapacity: true) }
                return
            }
            let jpeg = buffer.subdata(in: soi.lowerBound..<eoi.upperBound)
            buffer.removeSubrange(buffer.startIndex..<eoi.upperBound)
            delegate?.cameraStream(self, jpeg: jpeg)
        }
    }
}

extension CameraStreamClient: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            delegate?.cameraStream(self, ended: URLError(.badServerResponse))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        switch codec {
        case .mjpeg:
            buffer.append(data)
            drainJPEG()
        case .h264:
            delegate?.cameraStream(self, h264: data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if isStopping { return }
        if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
        self.task = nil
        delegate?.cameraStream(self, ended: error)
    }
}
