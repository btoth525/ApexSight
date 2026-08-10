import SwiftUI

/// A slim banner for the Review / Activity feeds that explains the house-mode camera filter — so a
/// camera missing from the feed reads as "hidden by Home mode," never "footage vanished" — and lets
/// the user flip between the mode-filtered view and every camera. Renders nothing when there's
/// nothing to say (Away mode mutes no cameras, or the relay hasn't reported a mode yet).
struct FeedModeFilterBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if !appState.houseModeMutedCameras.isEmpty {
            let count = appState.houseModeMutedCameras.count
            let modeTitle = HouseModeOption.forKey(appState.houseMode).title
            HStack(spacing: GlassTheme.Space.s) {
                Image(systemName: appState.showAllCamerasInFeeds
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(GlassTheme.accent)
                Text(appState.showAllCamerasInFeeds
                     ? "Showing all cameras"
                     : "\(modeTitle) mode — hiding \(count) camera\(count == 1 ? "" : "s")")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(GlassTheme.secondary)
                    // No lineLimit: this is the ONLY explanation of why cameras are missing from
                    // the feed, and at the accessibility Dynamic Type sizes .footnote scales into
                    // it truncated to "Home mode — hi…". A low-vision user then saw a feed short
                    // seven cameras with no legible reason — exactly the "footage vanished" read
                    // this banner exists to prevent. Worst case it wraps one line taller.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: GlassTheme.Space.s)
                Button(appState.showAllCamerasInFeeds ? "Filter" : "Show all") {
                    Haptics.tap()
                    appState.showAllCamerasInFeeds.toggle()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GlassTheme.accent)
            }
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, 8)
            .background(GlassTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1))
            .animation(.easeInOut(duration: 0.2), value: appState.showAllCamerasInFeeds)
        }
    }
}
