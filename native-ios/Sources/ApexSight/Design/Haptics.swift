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

    /// Runs `work` on the main actor, synchronously when already there.
    ///
    /// The old form dispatched correctly at runtime but the compiler couldn't prove it:
    /// `DispatchQueue.main.async` is not actor-isolation evidence, so every UIFeedbackGenerator
    /// construction and call read as main-actor-isolated work from a nonisolated context — 11 of
    /// the app's strict-concurrency warnings, and errors under the Swift 6 language mode. Taking a
    /// `@MainActor` closure and using `assumeIsolated` on the fast path states the isolation that
    /// was always true.
    ///
    /// The synchronous fast path is deliberate: haptics have to fire on the same turn of the
    /// run loop as the touch, or the buzz lags the tap and the whole app feels loose. Hopping
    /// through a Task even when already on main would cost that.
    private static func run(_ work: @MainActor @escaping () -> Void) {
        let fire: @MainActor () -> Void = {
            // Respect Reduce Motion — people who enable it generally want less buzz too. One
            // guard here covers every Haptics call across the app. (Reading this flag is itself
            // main-actor isolated, so it lives inside the isolated closure.)
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            work()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { fire() }
        } else {
            Task { @MainActor in fire() }
        }
    }
}
