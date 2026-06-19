import ActivityKit
import SwiftUI
import WidgetKit

/// All-vector incident Live Activity: severity-tinted, with a big object glyph, a LIVE
/// pulse, and View Live / Dismiss actions. No images — so it renders crisply and reliably
/// on the Lock Screen and Dynamic Island whether the alert arrived in-app or via push.
struct IncidentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IncidentActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
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
        }
    }

    // MARK: - Lock Screen

    private func lockScreen(_ context: ActivityViewContext<IncidentActivityAttributes>) -> some View {
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
        .widgetURL(cameraDeepLink(context.attributes.camera))
    }

    // MARK: - Building blocks

    private func glyphBadge(title: String, severity: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(severityColor(severity).opacity(0.18))
            Circle().strokeBorder(severityColor(severity).opacity(0.55), lineWidth: 2)
            Text(glyph(title)).font(.system(size: size * 0.5))
        }
        .frame(width: size, height: size)
    }

    private func liveTag(_ severity: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(severityColor(severity)).frame(width: 5, height: 5)
            Text(severity == "alert" ? "ALERT" : "LIVE")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(severityColor(severity))
        }
    }

    private func liveRow(camera: String, severity: String) -> some View {
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

    private func viewLiveButton(_ camera: String) -> some View {
        Link(destination: cameraDeepLink(camera)) {
            Label("View Live", systemImage: "play.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(.cyan, in: Capsule())
        }
    }

    private func viewLiveCircle(_ camera: String) -> some View {
        Link(destination: cameraDeepLink(camera)) {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.cyan)
                .frame(width: 40, height: 40)
                .background(.cyan.opacity(0.15), in: Circle())
        }
    }

    private func dismissButton(size: CGFloat) -> some View {
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
    private func cameraDeepLink(_ camera: String) -> URL {
        let encoded = camera.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? camera
        return URL(string: "apex://camera?name=\(encoded)") ?? URL(string: "apex://camera")!
    }

    /// The object emoji — the title already starts with it (e.g. "🚗 Car", "🧍 Person").
    private func glyph(_ title: String) -> String { String(title.first ?? "🔔") }

    private func severityColor(_ severity: String) -> Color {
        severity == "alert" ? .orange : .cyan
    }

    private func severityIcon(_ severity: String) -> String {
        severity == "alert" ? "bell.badge.fill" : "eye.fill"
    }

    private func titleizeName(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
