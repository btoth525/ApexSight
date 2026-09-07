import SwiftUI
import ImageIO
import UIKit

/// Plays an animated GIF (Frigate's event `preview.gif`) with correct per-frame timing. Auth rides
/// URLSession's shared cookie jar (the frigate_token cookie), same as every other image fetch.
/// Transparent until the GIF decodes, so a static poster placed behind it shows instantly and the
/// motion fades in — the "living thumbnail" look. Off-screen rows in a lazy list deinit the view,
/// so nothing animates that isn't on screen.
struct AnimatedGIFView: UIViewRepresentable {
    let url: URL
    var contentMode: UIView.ContentMode = .scaleAspectFit

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = contentMode
        iv.clipsToBounds = true
        iv.backgroundColor = .clear
        context.coordinator.load(url, into: iv)
        return iv
    }

    func updateUIView(_ iv: UIImageView, context: Context) {
        iv.contentMode = contentMode
        if context.coordinator.url != url { context.coordinator.load(url, into: iv) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private(set) var url: URL?
        private var task: URLSessionDataTask?

        func load(_ url: URL, into iv: UIImageView) {
            self.url = url
            task?.cancel()
            task = URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = Coordinator.decode(data) else { return }
                DispatchQueue.main.async { iv.image = image }
            }
            task?.resume()
        }

        private static func decode(_ data: Data) -> UIImage? {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
            let count = CGImageSourceGetCount(src)
            guard count > 1 else { return UIImage(data: data) }
            var frames: [UIImage] = []
            var duration = 0.0
            for i in 0..<count {
                guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                duration += frameDelay(src, i)
                frames.append(UIImage(cgImage: cg))
            }
            guard !frames.isEmpty else { return nil }
            return UIImage.animatedImage(with: frames, duration: duration > 0 ? duration : Double(frames.count) / 10)
        }

        private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                  let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
            let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            return d < 0.02 ? 0.1 : d   // clamp absurdly-fast frames like browsers do
        }
    }
}
