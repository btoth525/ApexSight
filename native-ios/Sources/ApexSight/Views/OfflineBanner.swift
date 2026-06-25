import SwiftUI

/// A slim banner that drops in from the top when the server can't be reached, so the
/// user knows the lists may be stale rather than assuming everything is live.
struct OfflineBanner: View {
    @EnvironmentObject private var appState: AppState

    private var isVisible: Bool {
        appState.session != nil && !appState.isReachable
    }

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: "wifi.slash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GlassTheme.orange)
                    Text("Can't reach your server — showing last data")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(GlassTheme.primary)
                }
                .padding(.horizontal, GlassTheme.Space.m)
                .padding(.vertical, GlassTheme.Space.s)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1)
                }
                .padding(.top, GlassTheme.Space.xs)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Offline. Showing the last loaded data.")
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isVisible)
    }
}
