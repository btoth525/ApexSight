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
                    Text("Live since \(context.attributes.startedAt, style: .time) · \(titleizeName(context.attributes.camera))")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: severityIcon(context.state.severity))
                    .foregroundStyle(severityColor(context.state.severity))
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 12, weight: .heavy))
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: severityIcon(context.state.severity))
                    .foregroundStyle(severityColor(context.state.severity))
            }
            .widgetURL(URL(string: "apex://camera?name=\(context.attributes.camera)"))
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
            }
            Spacer()
            Text(context.attributes.startedAt, style: .timer)
                .font(.system(size: 13, weight: .black, design: .rounded))
                .foregroundStyle(.cyan)
                .frame(maxWidth: 56)
        }
        .padding(16)
    }

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
