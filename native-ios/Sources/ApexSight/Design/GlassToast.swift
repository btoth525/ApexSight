import SwiftUI

/// The app's one transient message: a glass capsule at the bottom, optional status glyph, and a
/// Reduce-Motion-aware entrance. Every screen that briefly confirms or complains uses this — it
/// used to be four different capsules with four materials, radii, offsets and animation rules.
struct GlassToast: View {
    let text: String
    var isError = false
    var systemImage: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: GlassTheme.Space.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isError ? GlassTheme.red : GlassTheme.green)
            }
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GlassTheme.primary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, GlassTheme.Space.l)
        .padding(.vertical, GlassTheme.Space.m)
        .liquidGlass(in: Capsule(), fallbackMaterial: .ultraThinMaterial)
        .padding(.horizontal, GlassTheme.Space.l)
        .padding(.bottom, GlassTheme.Space.l)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
