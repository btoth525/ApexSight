import SwiftUI

struct LiveBannerModel: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let reviewID: String
}

/// Transient toast shown when a new alert-severity review arrives while the app
/// is foregrounded. Tapping deep-links to the review; auto-dismisses after a few seconds.
struct LiveAlertBanner: View {
    @EnvironmentObject private var appState: AppState
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        VStack {
            if let banner = appState.liveBanner {
                bannerCard(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear { scheduleDismiss(banner) }
            }
            Spacer()
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.liveBanner)
        .padding(.horizontal, 14)
    }

    private func bannerCard(_ banner: LiveBannerModel) -> some View {
        Button {
            appState.deepLink = .review(banner.reviewID)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(GlassTheme.orange.opacity(0.18)).frame(width: 42, height: 42)
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(GlassTheme.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                        .lineLimit(1)
                    Text(banner.body)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(GlassTheme.tertiary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(GlassTheme.orange.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in if value.translation.height < -20 { dismiss() } }
        )
    }

    private func scheduleDismiss(_ banner: LiveBannerModel) {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            if appState.liveBanner?.id == banner.id { dismiss() }
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        appState.liveBanner = nil
    }
}
