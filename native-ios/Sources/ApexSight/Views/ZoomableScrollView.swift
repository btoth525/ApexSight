import SwiftUI
import UIKit

/// A scroll view wrapper that enables pinch-to-zoom and double-tap-to-zoom on any SwiftUI content.
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
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

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostVC.rootView = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostVC: UIHostingController<Content>

        init(content: Content) {
            hostVC = UIHostingController(rootView: content)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { hostVC.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let view = scrollView.subviews.first else { return }
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
                let tapPoint = gesture.location(in: scrollView.subviews.first)
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
