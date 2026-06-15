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
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 13, weight: .heavy))
                    Text("Can't reach your server — showing last data")
                        .font(.system(size: 13, weight: .heavy))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(GlassTheme.orange.opacity(0.92), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Offline. Showing the last loaded data.")
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isVisible)
    }
}
