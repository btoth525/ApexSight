import SwiftUI
import UIKit

extension View {
    /// Re-enables the native swipe-from-the-left-edge "back" gesture on a pushed view whose
    /// navigation bar is hidden. UIKit disables `interactivePopGestureRecognizer` whenever the
    /// bar is hidden, which strands immersive full-screen views (e.g. the live player) on the
    /// hidden close button. This restores the gesture, but only when there's something to pop.
    func swipeBackEnabled() -> some View {
        background(SwipeBackEnabler())
    }
}

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false   // purely a hook into the nav controller
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        // The nav controller isn't wired up until the host is in the hierarchy — defer one hop.
        DispatchQueue.main.async {
            guard let nav = vc.navigationController,
                  let gesture = nav.interactivePopGestureRecognizer else { return }
            context.coordinator.nav = nav
            gesture.isEnabled = true
            gesture.delegate = context.coordinator
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var nav: UINavigationController?

        // Only let the swipe begin when there's a previous screen to return to.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (nav?.viewControllers.count ?? 0) > 1
        }

        // Don't fight the player's own pan/zoom gestures.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }
}
