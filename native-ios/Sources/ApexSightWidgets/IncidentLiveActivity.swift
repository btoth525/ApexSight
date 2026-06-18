import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

struct IncidentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IncidentActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(titleizeName(context.attributes.camera))
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: severityIcon(context.state.severity))
                            .foregroundStyle(severityColor(context.state.severity))
                    }
                    .font(.system(size: 13, weight: .black))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .time)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
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
                    expandedBottom(context)
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

    // MARK: - Expanded Dynamic Island bottom

    @ViewBuilder
    private func expandedBottom(_ context: ActivityViewContext<IncidentActivityAttributes>) -> some View {
        let image = snapshotImage(context.state.snapshotName)
        VStack(spacing: 10) {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 122)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(severityColor(context.state.severity).opacity(0.55), lineWidth: 1)
                    )
            }
            controlsBar(context.attributes.camera, showTime: image == nil ? context.attributes.startedAt : nil)
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreen(_ context: ActivityViewContext<IncidentActivityAttributes>) -> some View {
        if let image = snapshotImage(context.state.snapshotName) {
            // Snapshot hero: the detection image fills the banner with the details and
            // actions floating over a darkening gradient — the bad-ass version.
            ZStack(alignment: .bottom) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .clipped()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: severityIcon(context.state.severity))
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(severityColor(context.state.severity))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(context.state.title)
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(context.state.detail) · \(context.attributes.startedAt, style: .time)")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                    }
                    controlsBar(context.attributes.camera, showTime: nil)
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .widgetURL(cameraDeepLink(context.attributes.camera))
        } else {
            textOnlyLockScreen(context)
        }
    }

    /// Fallback when no snapshot has been cached yet (image still downloading, or none
    /// available) — the original icon + text + actions row.
    private func textOnlyLockScreen(_ context: ActivityViewContext<IncidentActivityAttributes>) -> some View {
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

    // MARK: - Shared controls

    /// View Live (opens the camera) + optional time + Dismiss (clears the alert).
    private func controlsBar(_ camera: String, showTime: Date?) -> some View {
        HStack(spacing: 12) {
            Link(destination: cameraDeepLink(camera)) {
                Label("View Live", systemImage: "video.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.cyan, in: Capsule())
            }
            Spacer()
            if let showTime {
                Text(showTime, style: .time)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.secondary)
            }
            Button(intent: ApexDismissIncidentIntent()) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    /// Loads the cached incident snapshot from the shared container. Live Activities can
    /// only render local files, so the app downloads it there first (see
    /// `IncidentActivityController`); nil falls back to the text-only layout.
    private func snapshotImage(_ name: String?) -> Image? {
        guard
            let name,
            let url = SharedSnapshotStore.incidentSnapshotURL(named: name),
            let ui = UIImage(contentsOfFile: url.path)
        else { return nil }
        return Image(uiImage: ui)
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
