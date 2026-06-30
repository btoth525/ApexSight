import SwiftUI

/// iOS 27 (WWDC 2026) platform adoptions, each gated behind `@available(iOS 27, *)` with the
/// existing iOS 17 path preserved as the `else` branch. Centralised here so the whole app adopts
/// the new APIs through one audited surface — and so the gates are trivial to find and remove once
/// the deployment target eventually rises.
///
/// Every symbol here was verified against the iOS 27.0 SDK swiftinterface (not the WWDC notes —
/// the notes said `.onScroll`, the real API is `.onScrollDown`/`.onScrollUp`).
extension View {

    /// Auto-collapse the nav bar while scrolling a content-forward screen (the camera wall, the
    /// recordings list) so the video/content gets the full height. Falls back to the normal,
    /// always-visible toolbar on iOS < 27.
    @ViewBuilder
    func ios27ToolbarMinimizeOnScroll() -> some View {
        if #available(iOS 27.0, *) {
            self.toolbarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
