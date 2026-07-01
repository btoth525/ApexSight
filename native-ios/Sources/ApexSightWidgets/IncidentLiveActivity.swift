import ActivityKit
import SwiftUI
import WidgetKit

/// All-vector incident Live Activity: severity-tinted, with a big object glyph, a LIVE
/// pulse, and View Live / Dismiss actions. No images — so it renders crisply and reliably
/// on the Lock Screen and Dynamic Island whether the alert arrived in-app or via push.
///
/// iOS 17 path: Lock Screen + Dynamic Island. The iOS-18 `IncidentLiveActivityCarPlay` variant
/// (chosen in the widget bundle) additionally supports the `.small` supplemental activity family,
/// which surfaces the activity on the **CarPlay Dashboard** (iOS 26+) and the **Watch Smart Stack**.
struct IncidentLiveActivity: Widget {
    // SE-0360: an `if #available` may return different opaque types per OS. On iOS 18+ we add the
    // `.small` supplemental family (CarPlay Dashboard + Watch Smart Stack); iOS 17 keeps the
    // Lock Screen / Dynamic Island activity unchanged.
    var body: some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return activityConfiguration.supplementalActivityFamilies([.small])
        } else {
            return activityConfiguration
        }
    }

    private var activityConfiguration: some WidgetConfiguration {
        ActivityConfiguration(for: IncidentActivityAttributes.self) { context in
            activityContent(context)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            IncidentActivityRenderer.dynamicIsland(context)
        }
    }

    /// On iOS 18+ the layout adapts to the activity family (compact banner on CarPlay / Watch);
    /// on iOS 17 it's always the Lock Screen layout.
    @ViewBuilder
    private func activityContent(_ context: ActivityViewContext<IncidentActivityAttributes>) -> some View {
        if #available(iOS 18.0, *) {
            IncidentActivityFamilyContent(context: context)
        } else {
            IncidentActivityRenderer.lockScreen(context)
        }
    }
}

/// Picks the layout by activity family: the compact banner on CarPlay / Watch (`.small`), the full
/// Lock Screen everywhere else.
@available(iOS 18.0, *)
private struct IncidentActivityFamilyContent: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<IncidentActivityAttributes>

    var body: some View {
        switch activityFamily {
        case .small: IncidentActivityRenderer.smallBanner(context)
        default: IncidentActivityRenderer.lockScreen(context)
        }
    }
}

/// Shared rendering for both Live Activity variants (keeps the iOS 17 and iOS 18 configs identical).
enum IncidentActivityRenderer {

    // MARK: - Dynamic Island

    static func dynamicIsland(_ context: ActivityViewContext<IncidentActivityAttributes>) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                glyphBadge(title: context.state.title, severity: context.state.severity, size: 42)
            }
            DynamicIslandExpandedRegion(.trailing) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Date(timeIntervalSince1970: context.attributes.startedAt), style: .time)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                    liveTag(context.state.severity)
                }
            }
            DynamicIslandExpandedRegion(.center) {
                VStack(spacing: 2) {
                    Text(context.state.title)
                        .font(.system(size: 15, weight: .black))
                        .lineLimit(1)
                    Text(context.state.detail)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                HStack(spacing: 10) {
                    viewLiveButton(context.attributes.camera)
                    dismissButton(size: 38)
                }
                .padding(.top, 2)
            }
        } compactLeading: {
            Image(systemName: severityIcon(context.state.severity))
                .foregroundStyle(severityColor(context.state.severity))
        } compactTrailing: {
            // The object glyph (the title already starts with it, e.g. "🧍"/"🚗").
            Text(glyph(context.state.title)).font(.system(size: 14))
        } minimal: {
            Image(systemName: severityIcon(context.state.severity))
                .foregroundStyle(severityColor(context.state.severity))
        }
        // Severity-colored hairline around the expanded island (orange alert / cyan detection).
        .keylineTint(severityColor(context.state.severity))
    }

    // MARK: - Lock Screen

    static func lockScreen(_ context: ActivityViewContext<IncidentActivityAttributes>) -> some View {
        HStack(spacing: 0) {
            // A bold severity accent bar down the leading edge.
            severityColor(context.state.severity)
                .frame(width: 4)
            HStack(spacing: 13) {
                glyphBadge(title: context.state.title, severity: context.state.severity, size: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.title)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(context.state.detail)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    liveRow(camera: context.attributes.camera,
                            severity: context.state.severity)
                }
                Spacer(minLength: 6)
                viewLiveCircle(context.attributes.camera)
                dismissButton(size: 40)
            }
            .padding(14)
        }
        // Dim once the activity has gone stale (e.g. a relay push stopped arriving) so the
        // Lock Screen signals "this is no longer live" instead of showing frozen-fresh data.
        .opacity(context.isStale ? 0.55 : 1)
        .widgetURL(cameraDeepLink(context.attributes.camera))
    }

    // MARK: - Small banner (CarPlay Dashboard / Watch Smart Stack)

    /// One glanceable, tappable line — no video (CarPlay forbids it while driving) and no action
    /// buttons (the small family is a summary surface). Tapping opens the camera in the app.
    static func smallBanner(_ context: ActivityViewContext<IncidentActivityAttributes>) -> some View {
        HStack(spacing: 10) {
            glyphBadge(title: context.state.title, severity: context.state.severity, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(titleizeName(context.attributes.camera))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            liveTag(context.state.severity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(context.isStale ? 0.55 : 1)
        .widgetURL(cameraDeepLink(context.attributes.camera))
    }

    // MARK: - Building blocks

    static func glyphBadge(title: String, severity: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(severityColor(severity).opacity(0.18))
            Circle().strokeBorder(severityColor(severity).opacity(0.55), lineWidth: 2)
            Text(glyph(title)).font(.system(size: size * 0.5))
        }
        .frame(width: size, height: size)
    }

    static func liveTag(_ severity: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(severityColor(severity)).frame(width: 5, height: 5)
            Text(severity == "alert" ? "ALERT" : "LIVE")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(severityColor(severity))
        }
    }

    static func liveRow(camera: String, severity: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(severityColor(severity)).frame(width: 6, height: 6)
            Text(severity == "alert" ? "LIVE ALERT" : "LIVE")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(severityColor(severity))
            Text("· \(titleizeName(camera))")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
    }

    static func viewLiveButton(_ camera: String) -> some View {
        Link(destination: cameraDeepLink(camera)) {
            Label("View Live", systemImage: "play.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(.cyan, in: Capsule())
        }
    }

    static func viewLiveCircle(_ camera: String) -> some View {
        Link(destination: cameraDeepLink(camera)) {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.cyan)
                .frame(width: 40, height: 40)
                .background(.cyan.opacity(0.15), in: Circle())
        }
    }

    static func dismissButton(size: CGFloat) -> some View {
        Button(intent: ApexDismissIncidentIntent()) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: size, height: size)
                .background(.white.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    /// Percent-encode the camera name so names with spaces/specials still build a valid URL.
    static func cameraDeepLink(_ camera: String) -> URL {
        let encoded = camera.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? camera
        return URL(string: "apex://camera?name=\(encoded)")
            ?? URL(string: "apex://camera")
            ?? URL(fileURLWithPath: "/")
    }

    /// The object emoji — the title usually starts with it (e.g. "🚗 Car", "🧍 Person"). If a
    /// push-started state arrives with a plain title (no emoji prefix), fall back to a bell
    /// rather than slicing a bare letter like "P".
    static func glyph(_ title: String) -> String {
        guard let first = title.unicodeScalars.first, first.properties.isEmoji else { return "🔔" }
        return String(title.first ?? "🔔")
    }

    static func severityColor(_ severity: String) -> Color {
        severity == "alert" ? .orange : .cyan
    }

    static func severityIcon(_ severity: String) -> String {
        severity == "alert" ? "bell.badge.fill" : "eye.fill"
    }

    static func titleizeName(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
