import SwiftUI
import WidgetKit
import UIKit

// MARK: - Local theme (widget target has no access to the app's GlassTheme)

private enum WidgetTheme {
    static let accent = Color(red: 0.0, green: 0.83, blue: 0.95)        // cyan
    static let accentBlue = Color(red: 0.15, green: 0.45, blue: 0.95)   // vivid blue
    static let alertDot = Color.orange
    static let detectionDot = Color(red: 0.0, green: 0.83, blue: 0.95)

    static let panelGradient = LinearGradient(
        colors: [
            Color(red: 0.06, green: 0.10, blue: 0.14),
            Color(red: 0.02, green: 0.03, blue: 0.05)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Timeline entry

struct CameraSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedCameraSnapshot?
    let imageURL: URL?
    let alert: SharedAlert?
    let alertImageURL: URL?
}

// MARK: - Provider

struct CameraSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> CameraSnapshotEntry {
        CameraSnapshotEntry(date: Date(), snapshot: nil, imageURL: nil, alert: nil, alertImageURL: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (CameraSnapshotEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CameraSnapshotEntry>) -> Void) {
        let current = entry()
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [current], policy: .after(refresh)))
    }

    private func entry() -> CameraSnapshotEntry {
        let cached = SharedSnapshotStore.load()
        let latestAlert = SharedSnapshotStore.loadLatestAlert()
        return CameraSnapshotEntry(
            date: Date(),
            snapshot: cached?.snapshot,
            imageURL: cached?.imageURL,
            alert: latestAlert?.alert,
            alertImageURL: latestAlert?.imageURL
        )
    }
}

// MARK: - Root view

struct CameraSnapshotWidgetView: View {
    let entry: CameraSnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                AccessoryInlineView(entry: entry)
            case .accessoryRectangular:
                AccessoryRectangularView(entry: entry)
                    .containerBackground(.clear, for: .widget)
            case .systemSmall:
                SmallWidgetView(entry: entry)
                    .containerBackground(WidgetTheme.panelGradient, for: .widget)
            case .systemMedium:
                MediumWidgetView(entry: entry)
                    .containerBackground(WidgetTheme.panelGradient, for: .widget)
            case .systemLarge:
                LargeWidgetView(entry: entry)
                    .containerBackground(WidgetTheme.panelGradient, for: .widget)
            default:
                SmallWidgetView(entry: entry)
                    .containerBackground(WidgetTheme.panelGradient, for: .widget)
            }
        }
        .widgetURL(widgetURL)
    }

    private var widgetURL: URL? {
        // Prefer the alert's camera when an alert is present.
        if let alertCamera = entry.alert?.camera,
           let encoded = alertCamera.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "apex://camera?name=\(encoded)")
        }
        guard let camera = entry.snapshot?.camera.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return URL(string: "apex://")
        }
        return URL(string: "apex://camera?name=\(camera)")
    }
}

// MARK: - Hero snapshot image

private struct HeroSnapshotImage: View {
    let imageURL: URL?

    var body: some View {
        if let imageURL, let image = UIImage(contentsOfFile: imageURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            PlaceholderHero()
        }
    }
}

private struct PlaceholderHero: View {
    var body: some View {
        ZStack {
            WidgetTheme.panelGradient
            // Subtle accent glow
            RadialGradient(
                colors: [WidgetTheme.accent.opacity(0.18), .clear],
                center: .center,
                startRadius: 4,
                endRadius: 140
            )
            VStack(spacing: 10) {
                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(WidgetTheme.accent)
                Text("Open ApexSight to start")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .padding(8)
        }
    }
}

// MARK: - Small

private struct SmallWidgetView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroSnapshotImage(imageURL: entry.imageURL)

            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            // Freshness badge (top-trailing)
            VStack {
                HStack {
                    if let alert = entry.alert {
                        AlertPill(alert: alert)
                    }
                    Spacer()
                    if let snapshot = entry.snapshot {
                        FreshnessBadge(capturedAt: snapshot.capturedAt)
                    }
                }
                Spacer()
            }
            .padding(10)

            VStack(alignment: .leading, spacing: 3) {
                Label(entry.snapshot.map { titleizeWidget($0.camera) } ?? "ApexSight", systemImage: "video.fill")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .lineLimit(1)

                Text(snapshotSubtitle)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
    }

    private var snapshotSubtitle: String {
        guard let snapshot = entry.snapshot else { return "Cache a snapshot" }
        return "\(snapshot.serverName) · \(relativeShort(snapshot.capturedAt))"
    }
}

// MARK: - Medium

private struct MediumWidgetView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        HStack(spacing: 0) {
            // Hero image, leading ~55%
            GeometryReader { proxy in
                ZStack(alignment: .bottomLeading) {
                    HeroSnapshotImage(imageURL: entry.imageURL)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.snapshot.map { titleizeWidget($0.camera) } ?? "ApexSight")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .lineLimit(1)
                        if let snapshot = entry.snapshot {
                            Text(relativeShort(snapshot.capturedAt))
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)

                    VStack {
                        HStack {
                            Spacer()
                            if let snapshot = entry.snapshot {
                                FreshnessBadge(capturedAt: snapshot.capturedAt)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(0.55)

            // Info column, trailing
            InfoColumn(entry: entry)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0.45)
        }
    }
}

private struct InfoColumn: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader()

            if let alert = entry.alert {
                AlertDetail(alert: alert)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No recent activity")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("You're all clear")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Large

private struct LargeWidgetView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader()
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Hero
            ZStack(alignment: .bottomLeading) {
                HeroSnapshotImage(imageURL: entry.imageURL)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 2) {
                    Label(entry.snapshot.map { titleizeWidget($0.camera) } ?? "ApexSight", systemImage: "video.fill")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .lineLimit(1)
                    if let snapshot = entry.snapshot {
                        Text("\(snapshot.serverName) · \(relativeShort(snapshot.capturedAt))")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
                .foregroundStyle(.white)
                .padding(14)

                VStack {
                    HStack {
                        Spacer()
                        if let snapshot = entry.snapshot {
                            FreshnessBadge(capturedAt: snapshot.capturedAt)
                        }
                    }
                    Spacer()
                }
                .padding(12)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 14)

            // Divider
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [WidgetTheme.accent.opacity(0.5), WidgetTheme.accentBlue.opacity(0.0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Latest activity row
            HStack {
                Text("LATEST ACTIVITY")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(WidgetTheme.accent)
                    .tracking(1.2)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if let alert = entry.alert {
                AlertDetail(alert: alert, large: true)
                    .padding(.horizontal, 14)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(WidgetTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No recent activity")
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("All your cameras are quiet")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Shared components

private struct WidgetHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(WidgetTheme.accent)
            Text("APEXSIGHT")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .tracking(1.5)
            Spacer(minLength: 0)
        }
    }
}

private struct AlertDetail: View {
    let alert: SharedAlert
    var large: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: large ? 12 : 8) {
            Text(alertEmoji(alert.label))
                .font(.system(size: large ? 32 : 24))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    SeverityDot(severity: alert.severity)
                    Text(titleizeWidget(alert.subLabel ?? alert.label))
                        .font(.system(size: large ? 16 : 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(titleizeWidget(alert.camera))
                    .font(.system(size: large ? 12 : 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(relativeShort(alert.when))
                    .font(.system(size: large ? 11 : 10, weight: .heavy))
                    .foregroundStyle(WidgetTheme.accent.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AlertPill: View {
    let alert: SharedAlert

    var body: some View {
        HStack(spacing: 3) {
            Text(alertEmoji(alert.label))
                .font(.system(size: 10))
            Text(relativeShort(alert.when))
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(
            Capsule().strokeBorder(severityColor(alert.severity).opacity(0.8), lineWidth: 1)
        )
    }
}

private struct SeverityDot: View {
    let severity: String

    var body: some View {
        Circle()
            .fill(severityColor(severity))
            .frame(width: 8, height: 8)
            .overlay(
                Circle().fill(severityColor(severity).opacity(0.4)).frame(width: 14, height: 14)
                    .blur(radius: 3)
            )
    }
}

private struct FreshnessBadge: View {
    let capturedAt: Date

    var body: some View {
        let age = ageMinutes(capturedAt)
        Text(age == 0 ? "LIVE" : "\(age)m")
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(age > 5 ? Color.orange : WidgetTheme.accent, in: Capsule())
    }
}

// MARK: - Lock screen

private struct AccessoryRectangularView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        if let alert = entry.alert {
            HStack(spacing: 6) {
                Text(alertEmoji(alert.label))
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleizeWidget(alert.subLabel ?? alert.label))
                        .font(.system(size: 13, weight: .black))
                        .lineLimit(1)
                    Text("\(titleizeWidget(alert.camera)) · \(relativeShort(alert.when))")
                        .font(.system(size: 11, weight: .heavy))
                        .opacity(0.8)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else if let snapshot = entry.snapshot {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.system(size: 12, weight: .black))
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleizeWidget(snapshot.camera))
                        .font(.system(size: 13, weight: .black))
                        .lineLimit(1)
                    Text(relativeShort(snapshot.capturedAt))
                        .font(.system(size: 11, weight: .heavy))
                        .opacity(0.8)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else {
            Label("ApexSight", systemImage: "video.badge.waveform")
                .font(.system(size: 13, weight: .black))
        }
    }
}

private struct AccessoryInlineView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        if let alert = entry.alert {
            Label(
                "\(alertEmoji(alert.label)) \(titleizeWidget(alert.subLabel ?? alert.label)) · \(titleizeWidget(alert.camera))",
                systemImage: "video.fill"
            )
        } else if let snapshot = entry.snapshot {
            Label("\(titleizeWidget(snapshot.camera)) · \(relativeShort(snapshot.capturedAt))", systemImage: "video.fill")
        } else {
            Label("ApexSight", systemImage: "video.fill")
        }
    }
}

// MARK: - Widget configuration

struct CameraSnapshotWidget: Widget {
    let kind = "CameraSnapshotWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CameraSnapshotProvider()) { entry in
            CameraSnapshotWidgetView(entry: entry)
        }
        .configurationDisplayName("ApexSight Live")
        .description("Your live camera snapshot plus the latest detection from your cameras.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// MARK: - Helpers

private func titleizeWidget(_ value: String) -> String {
    value
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

private func alertEmoji(_ label: String) -> String {
    switch label.lowercased() {
    case "person": return "🧍"
    case "car": return "🚗"
    case "truck": return "🚚"
    case "dog": return "🐕"
    case "cat": return "🐈"
    case "bicycle": return "🚲"
    case "package": return "📦"
    case "bird": return "🐦"
    default: return "📹"
    }
}

private func severityColor(_ severity: String) -> Color {
    severity.lowercased() == "alert" ? WidgetTheme.alertDot : WidgetTheme.detectionDot
}

private func ageMinutes(_ date: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(date) / 60))
}

private func relativeShort(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "Just now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    let days = hours / 24
    return "\(days)d ago"
}
