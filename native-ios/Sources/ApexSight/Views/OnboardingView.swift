import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "video.fill",
            tint: GlassTheme.blue,
            title: "Every Camera, Instantly",
            subtitle: "Live HLS & WebRTC streams, PTZ control, and a frosted-glass grid of every Frigate camera on your network."
        ),
        OnboardingPage(
            icon: "magnifyingglass",
            tint: GlassTheme.cyan,
            title: "Search Like You Remember It",
            subtitle: "Describe what you saw — \u{201C}kid on a bike\u{201D} — with semantic search, or filter by camera, object, sub-label, and zone."
        ),
        OnboardingPage(
            icon: "clock.arrow.circlepath",
            tint: GlassTheme.purple,
            title: "Scrub the Timeline",
            subtitle: "Jump through a 24-hour activity timeline, replay any moment, and save clips straight to your photo library."
        ),
        OnboardingPage(
            icon: "bell.badge.fill",
            tint: GlassTheme.orange,
            title: "Alerts That Respect You",
            subtitle: "Rich notifications with snapshots, per-camera and per-zone controls, quiet hours, and cooldowns to kill alert fatigue."
        )
    ]

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        pageView(item).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: page)

                pageIndicator
                    .padding(.bottom, 28)

                controls
                    .padding(.horizontal, 24)
                    .padding(.bottom, 44)
            }
        }
    }

    private func pageView(_ item: OnboardingPage) -> some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle()
                    .fill(item.tint.opacity(0.18))
                    .frame(width: 168, height: 168)
                    .blur(radius: 6)
                Image(systemName: item.icon)
                    .font(.system(size: 64, weight: .black))
                    .foregroundStyle(item.tint)
            }
            VStack(spacing: 14) {
                Text(item.title)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(GlassTheme.primary)
                    .multilineTextAlignment(.center)
                Text(item.subtitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GlassTheme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? GlassTheme.cyan : Color.white.opacity(0.2))
                    .frame(width: index == page ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: page)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    Task {
                        _ = try? await NativeNotificationManager.requestPermission()
                    }
                    hasCompletedOnboarding = true
                }
            } label: {
                Text(page < pages.count - 1 ? "Continue" : "Get Started")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(GlassTheme.cyan, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                hasCompletedOnboarding = true
            } label: {
                Text("Skip")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(GlassTheme.secondary)
            }
            .opacity(page < pages.count - 1 ? 1 : 0)
        }
    }
}

private struct OnboardingPage {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
}
