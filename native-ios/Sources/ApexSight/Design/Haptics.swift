import UIKit

/// Centralized haptics so every interaction across ApexSight feels tactile and
/// consistent. Generators are `prepare()`d right before firing to minimize latency.
/// All calls hop to the main actor (UIFeedbackGenerator must run on the main thread).
enum Haptics {
    /// Light tap — the default for a button press anywhere in the app.
    static func tap() { impact(.light) }

    /// Soft, rounded press — for larger primary actions.
    static func press() { impact(.soft) }

    /// Selection tick — segmented pickers, toggles, tab changes.
    static func select() {
        run { let g = UISelectionFeedbackGenerator(); g.prepare(); g.selectionChanged() }
    }

    static func success() { notify(.success) }
    static func warning() { notify(.warning) }
    static func error() { notify(.error) }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        run { let g = UIImpactFeedbackGenerator(style: style); g.prepare(); g.impactOccurred() }
    }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        run { let g = UINotificationFeedbackGenerator(); g.prepare(); g.notificationOccurred(type) }
    }

    private static func run(_ work: @escaping () -> Void) {
        // Respect Reduce Motion — people who enable it generally want less buzz too. One
        // guard here covers every Haptics call across the app.
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
