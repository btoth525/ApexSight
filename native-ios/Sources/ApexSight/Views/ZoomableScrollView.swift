import SwiftUI
import UIKit

/// A scroll view wrapper that enables pinch-to-zoom and double-tap-to-zoom on any SwiftUI content.
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    let content: Content
    /// Called on a genuine single tap (waits for double-tap-to-zoom to fail first), so a
    /// view can toggle immersive chrome without fighting the zoom gestures.
    var onSingleTap: (() -> Void)? = nil

    init(onSingleTap: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.onSingleTap = onSingleTap
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 6.0
        scrollView.minimumZoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let hostVC = context.coordinator.hostVC
        hostVC.view.backgroundColor = .clear
        hostVC.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hostVC.view)
        NSLayoutConstraint.activate([
            hostVC.view.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            hostVC.view.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            hostVC.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostVC.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        if onSingleTap != nil {
            let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
            singleTap.numberOfTapsRequired = 1
            singleTap.require(toFail: doubleTap)   // never steals a double-tap-to-zoom
            scrollView.addGestureRecognizer(singleTap)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Propagate SwiftUI content changes into the hosted view. Without this the host is
        // frozen at its initial value — so a live WebRTC track (or a swapped AVPlayer/image)
        // that arrives a moment AFTER this view is inserted never reaches the screen, leaving
        // full-screen live black. Reassigning rootView lets the hosted representable's own
        // updateUIView run and attach the new track/player.
        context.coordinator.hostVC.rootView = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, onSingleTap: onSingleTap)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostVC: UIHostingController<Content>
        let onSingleTap: (() -> Void)?

        init(content: Content, onSingleTap: (() -> Void)?) {
            hostVC = UIHostingController(rootView: content)
            self.onSingleTap = onSingleTap
        }

        @objc func handleSingleTap() { onSingleTap?() }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { hostVC.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Center the zoomed content. While zoomed-out (or while the content is smaller
            // than the viewport on an axis) keep it pinned to the middle so the video / image
            // never drifts into a corner; once it overflows an axis the offset is 0 and the
            // user pans freely. Operate on the hosted view directly rather than guessing at
            // `subviews.first`, which can be a scroll indicator.
            guard let view = hostVC.view else { return }
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            view.center = CGPoint(
                x: scrollView.contentSize.width / 2 + offsetX,
                y: scrollView.contentSize.height / 2 + offsetY
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // Locate the tap in the hosted view (not subviews.first, which can be a
                // scroll indicator) so double-tap zooms to where the user actually tapped.
                let tapPoint = gesture.location(in: hostVC.view)
                let zoomRect = CGRect(
                    x: tapPoint.x - scrollView.bounds.width / 5,
                    y: tapPoint.y - scrollView.bounds.height / 5,
                    width: scrollView.bounds.width / 2.5,
                    height: scrollView.bounds.height / 2.5
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}
