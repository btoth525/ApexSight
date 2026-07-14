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
        // `toolbarMinimizeBehavior` only exists in the iOS 27 SDK. App Store Connect currently
        // REJECTS binaries built with the iOS 27 beta SDK (ITMS-90534), so we ship with the iOS 26.5
        // SDK (Swift 6.3.2) and compile this out; Xcode 27 ships Swift 6.4, so the block re-activates
        // automatically once we can build against the released iOS 27 SDK. (Apple's documented
        // `#if compiler` pattern for adopting a newer SDK's API without breaking older toolchains.)
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            self.toolbarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Guarantee at least the 44×44pt HIG minimum tap target for small icon-only controls, without
    /// changing their visual size. Expands the hittable area around the (usually ~16–34pt) glyph and
    /// makes the whole area tappable. Use on `Button` labels / tappable icons.
    func hitTarget(_ side: CGFloat = 44) -> some View {
        self
            .frame(minWidth: side, minHeight: side)
            .contentShape(Rectangle())
    }
}
