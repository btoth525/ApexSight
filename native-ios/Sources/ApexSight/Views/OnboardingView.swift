import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "video.fill",
            tint: GlassTheme.blue,
            title: "Every Camera, Instantly",
            subtitle: "Auto-playing live streams, WebRTC HD, PTZ control, and a frosted-glass wall of every Frigate camera on your network."
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
                    .padding(.bottom, GlassTheme.Space.xxl)

                controls
                    .padding(.horizontal, GlassTheme.Space.l)
                    .padding(.bottom, 44)
            }
        }
    }

    private func pageView(_ item: OnboardingPage) -> some View {
        VStack(spacing: GlassTheme.Space.xxl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(GlassTheme.surfaceHigh)
                    .frame(width: 132, height: 132)
                    .cardStroke(66)
                Image(systemName: item.icon)
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(item.tint)
            }
            VStack(spacing: GlassTheme.Space.m) {
                Text(item.title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(GlassTheme.primary)
                    .multilineTextAlignment(.center)
                Text(item.subtitle)
                    .font(.body)
                    .foregroundStyle(GlassTheme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, GlassTheme.Space.xxl)
            }
            Spacer()
        }
        .padding(.horizontal, GlassTheme.Space.s)
    }

    private var pageIndicator: some View {
        HStack(spacing: GlassTheme.Space.s) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? GlassTheme.accent : GlassTheme.separator)
                    .frame(width: index == page ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: page)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
    }

    private var controls: some View {
        VStack(spacing: GlassTheme.Space.m) {
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
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())

            Button {
                hasCompletedOnboarding = true
            } label: {
                Text("Skip")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(GlassTheme.secondary)
            }
            .opacity(page < pages.count - 1 ? 1 : 0)
            // On the last page it's invisible — also stop it intercepting taps below
            // "Get Started" (a mistap there would finish onboarding and skip the
            // notification-permission prompt).
            .allowsHitTesting(page < pages.count - 1)
        }
    }
}

private struct OnboardingPage {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
}
