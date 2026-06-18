import ActivityKit
import SwiftUI
import WidgetKit

struct IncidentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IncidentActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: severityIcon(context.state.severity))
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(severityColor(context.state.severity))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.system(size: 14, weight: .black))
                            .lineLimit(1)
                        Text(context.state.detail)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        Link(destination: cameraDeepLink(context.attributes.camera)) {
                            Label("View Live", systemImage: "video.fill")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(.cyan)
                        }
                        Spacer()
                        Text(context.attributes.startedAt, style: .time)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.secondary)
                        Button(intent: ApexDismissIncidentIntent()) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } compactLeading: {
                Image(systemName: severityIcon(context.state.severity))
                    .foregroundStyle(severityColor(context.state.severity))
            } compactTrailing: {
                // The object glyph (the title already starts with it, e.g. "🧍"/"📦"),
                // not a ticking timer — tells you what at a glance.
                Text(glyph(context.state.title))
                    .font(.system(size: 14))
            } minimal: {
                Image(systemName: severityIcon(context.state.severity))
                    .foregroundStyle(severityColor(context.state.severity))
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<IncidentActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(severityColor(context.state.severity).opacity(0.18)).frame(width: 46, height: 46)
                Image(systemName: severityIcon(context.state.severity))
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(severityColor(context.state.severity))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.title)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(context.state.detail)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text("\(context.attributes.startedAt, style: .time) · \(titleizeName(context.attributes.camera))")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // View Live (opens the camera) + Dismiss (clears the alert).
            Link(destination: cameraDeepLink(context.attributes.camera)) {
                Image(systemName: "video.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.cyan)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
            }
            Button(intent: ApexDismissIncidentIntent()) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .widgetURL(cameraDeepLink(context.attributes.camera))
    }

    /// Percent-encode the camera name so names with spaces/specials still build a valid URL.
    private func cameraDeepLink(_ camera: String) -> URL {
        let encoded = camera.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? camera
        return URL(string: "apex://camera?name=\(encoded)") ?? URL(string: "apex://camera")!
    }

    /// The object emoji for the compact Dynamic Island glance — the title already starts
    /// with it (e.g. "🧍 Person", "📦 Amazon").
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
