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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        VStack {
            if let banner = appState.liveBanner {
                bannerCard(banner)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .onAppear { scheduleDismiss(banner) }
                    .onDisappear { dismissTask?.cancel(); dismissTask = nil }
            }
            Spacer()
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8), value: appState.liveBanner)
        .padding(.horizontal, 14)
    }

    private func bannerCard(_ banner: LiveBannerModel) -> some View {
        Button {
            Haptics.tap()
            appState.deepLink = .review(banner.reviewID)
            dismiss()
        } label: {
            HStack(spacing: GlassTheme.Space.m) {
                ZStack {
                    Circle().fill(GlassTheme.orange.opacity(0.18)).frame(width: 42, height: 42)
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(GlassTheme.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.primary)
                        .lineLimit(1)
                    Text(banner.body)
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GlassTheme.tertiary)
            }
            .padding(GlassTheme.Space.m)
            .liquidGlass(in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous), fallbackMaterial: .ultraThinMaterial)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(banner.title). \(banner.body)")
        .accessibilityHint("Opens the review")
        .accessibilityAddTraits(.isButton)
        .padding(.top, GlassTheme.Space.s)
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
