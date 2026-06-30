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

    /// Dim custom overlay chrome (camera controls, wall badges) when the window/tile is inactive —
    /// the iOS 27 "appearsActive" affordance for iPad multitasking / Stage Manager / Mirroring.
    /// No-op below iOS 27. Implemented via the environment flag so call sites stay declarative.
    @ViewBuilder
    func ios27DimWhenInactive() -> some View {
        if #available(iOS 27.0, *) {
            self.modifier(AppearsActiveDim())
        } else {
            self
        }
    }
}

/// Reduces opacity when the hosting scene is not the active one. Reads the SwiftUI environment
/// `appearsActive` flag added in iOS 27; harmless on a single-window iPhone (always active).
@available(iOS 27.0, *)
private struct AppearsActiveDim: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive
    func body(content: Content) -> some View {
        content.opacity(appearsActive ? 1.0 : 0.55)
    }
}
