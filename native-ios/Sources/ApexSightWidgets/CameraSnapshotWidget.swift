import SwiftUI
import WidgetKit
import UIKit
import ImageIO

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
    let snapshotImageURL: URL?      // cached live frame (fallback hero only)
    let alerts: [SharedAlert]       // recent activity feed, newest first
    let heroImageURL: URL?          // snapshot of the most recent event
    /// Hero decoded ONCE per timeline entry (in the provider), so SwiftUI re-evaluating the
    /// widget body several times per render doesn't re-decode from disk on every pass —
    /// important inside the widget extension's tight memory/CPU budget.
    let heroImage: UIImage?

    /// The most recent event, if any.
    var latest: SharedAlert? { alerts.first }
}

// MARK: - Provider

struct CameraSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> CameraSnapshotEntry {
        CameraSnapshotEntry(date: Date(), snapshot: nil, snapshotImageURL: nil, alerts: [], heroImageURL: nil, heroImage: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (CameraSnapshotEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CameraSnapshotEntry>) -> Void) {
        Task {
            // Pull fresh alerts + hero straight from Frigate so the widget updates in
            // the background on WidgetKit's schedule — not only when the app is opened.
            await WidgetDataFetcher.refresh()
            let current = entry()
            let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [current], policy: .after(refresh)))
        }
    }

    private func entry() -> CameraSnapshotEntry {
        let cached = SharedSnapshotStore.load()
        let recent = SharedSnapshotStore.loadRecentAlerts()
        // Decode the hero once here (the latest event snapshot, else a cached camera frame),
        // downsampled to stay under the widget memory budget.
        let heroURL = recent.heroImageURL ?? cached?.imageURL
        let heroImage = heroURL.flatMap { downsampledImage(at: $0, maxPixel: 800) }
        return CameraSnapshotEntry(
            date: Date(),
            snapshot: cached?.snapshot,
            snapshotImageURL: cached?.imageURL,
            alerts: recent.alerts,
            heroImageURL: recent.heroImageURL,
            heroImage: heroImage
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
                    .containerBackground(.clear, for: .widget)
            case .accessoryRectangular:
                AccessoryRectangularView(entry: entry)
                    .containerBackground(.clear, for: .widget)
            case .accessoryCircular:
                AccessoryCircularView(entry: entry)
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
            case .systemExtraLarge:
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
        // Tap → open the exact event if we have one, otherwise its camera, otherwise the app.
        if let latest = entry.latest {
            if let id = latest.id,
               let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                return URL(string: "apex://review?id=\(encoded)")
            }
            if let encoded = latest.camera.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                return URL(string: "apex://camera?name=\(encoded)")
            }
        }
        if let camera = entry.snapshot?.camera.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "apex://camera?name=\(camera)")
        }
        return URL(string: "apex://")
    }
}

// MARK: - Hero snapshot image

private struct HeroSnapshotImage: View {
    /// Pre-decoded by the provider (once per timeline entry) — see CameraSnapshotEntry.heroImage.
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            PlaceholderHero()
        }
    }
}

/// ImageIO thumbnail decode — never inflates the full bitmap into memory, unlike
/// `UIImage(contentsOfFile:)`. Returns nil on any failure so the caller shows the placeholder.
private func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}

private struct PlaceholderHero: View {
    var body: some View {
        ZStack {
            WidgetTheme.panelGradient
            RadialGradient(
                colors: [WidgetTheme.accent.opacity(0.18), .clear],
                center: .center,
                startRadius: 4,
                endRadius: 140
            )
            VStack(spacing: 8) {
                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(WidgetTheme.accent)
                Text("No events yet")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .padding(8)
        }
    }
}

// MARK: - Small (hero of the latest event)

private struct SmallWidgetView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroSnapshotImage(image: entry.heroImage)

            LinearGradient(
                colors: [.clear, .black.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack {
                HStack {
                    if let latest = entry.latest {
                        SeverityChip(severity: latest.severity, when: latest.when)
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(9)

            VStack(alignment: .leading, spacing: 2) {
                if let latest = entry.latest {
                    Text("\(alertEmoji(latest.label)) \(titleizeWidget(latest.subLabel ?? latest.label))")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(titleizeWidget(latest.camera)) · \(relativeShort(latest.when))")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text("All clear")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .lineLimit(1)
                    Text("No recent events")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(11)
        }
    }
}

// MARK: - Medium (hero left, recent feed right)

private struct MediumWidgetView: View {
    let entry: CameraSnapshotEntry

    private var todayCount: Int {
        entry.alerts.filter { Calendar.current.isDateInToday($0.when) }.count
    }
    private var severityColor: Color {
        switch entry.latest?.severity {
        case "alert": return Color(red: 1.0, green: 0.27, blue: 0.30)   // red ring
        case "detection": return WidgetTheme.accent
        default: return .white.opacity(0.22)
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            // Left: the latest snapshot as a framed card with a severity-colored ring + label.
            ZStack(alignment: .bottomLeading) {
                Color.black
                HeroSnapshotImage(image: entry.heroImage)
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                if let latest = entry.latest {
                    HStack(spacing: 4) {
                        Text(alertEmoji(latest.label)).font(.system(size: 14))
                        Text(titleizeWidget(latest.subLabel ?? latest.label))
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(8)
                }
            }
            .frame(width: 158)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(severityColor, lineWidth: 2))

            // Right: a compact dashboard — header, recent events, and an always-present footer
            // (today count + arm state) so it never reads empty.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("ACTIVITY")
                        .font(.system(size: 10, weight: .black, design: .rounded)).tracking(1.2)
                        .foregroundStyle(WidgetTheme.accent)
                    Spacer()
                    if todayCount > 0 {
                        Text("\(todayCount) today")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.white.opacity(0.10), in: Capsule())
                    }
                }
                .padding(.bottom, 6)

                if entry.alerts.isEmpty {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(WidgetTheme.accent).font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("All clear").font(.system(size: 15, weight: .black, design: .rounded)).foregroundStyle(.white)
                            Text("No recent activity").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Spacer()
                } else {
                    VStack(spacing: 7) {
                        ForEach(Array(entry.alerts.prefix(3).enumerated()), id: \.offset) { _, alert in
                            EventFeedRow(alert: alert)
                        }
                    }
                    Spacer(minLength: 4)
                }

                ArmStatusFooter()
            }
            .padding(.vertical, 12)
            .padding(.trailing, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 11)
        .widgetURL(entry.latest.flatMap { $0.id }.map { URL(string: "apex://review?id=\($0)")! })
    }
}

/// Always-present footer strip: current arm state (read straight from the app group) — keeps the
/// widget's right column full and glanceable even when there's no recent activity.
private struct ArmStatusFooter: View {
    private var armMode: String {
        UserDefaults(suiteName: ApexAppGroup.identifier)?.string(forKey: "apex.armMode") ?? "away"
    }
    private var isDisarmed: Bool { armMode == "disarmed" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isDisarmed ? "shield.slash.fill" : "shield.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isDisarmed ? .white.opacity(0.5) : WidgetTheme.accent)
            Text(isDisarmed ? "Disarmed" : "Armed · \(armMode.capitalized)")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text("APEXSIGHT")
                .font(.system(size: 8, weight: .black, design: .rounded)).tracking(1.0)
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.top, 7)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }
}

// MARK: - Large (hero on top, recent feed below)

private struct LargeWidgetView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                HeroSnapshotImage(image: entry.heroImage)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.74)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                if let latest = entry.latest {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(alertEmoji(latest.label)) \(titleizeWidget(latest.subLabel ?? latest.label))")
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("\(titleizeWidget(latest.camera)) · \(relativeShort(latest.when))")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(13)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 14)

            HStack {
                Text("RECENT ACTIVITY")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(WidgetTheme.accent)
                    .tracking(1.2)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if entry.alerts.isEmpty {
                AllClearLarge()
                    .padding(.horizontal, 14)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(entry.alerts.prefix(4).enumerated()), id: \.offset) { _, alert in
                        EventFeedRow(alert: alert, large: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            if let latest = entry.latest {
                HStack(spacing: 8) {
                    Button(intent: ApexOpenCameraIntent(camera: latest.camera)) {
                        Label("View Live", systemImage: "video.fill")
                            .font(.system(size: 12, weight: .heavy))
                            .frame(maxWidth: .infinity)
                    }
                    Button(intent: ApexSnoozeIntent()) {
                        Label("Snooze", systemImage: "moon.zzz.fill")
                            .font(.system(size: 12, weight: .heavy))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(WidgetTheme.accent.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Shared components

private struct EventFeedRow: View {
    let alert: SharedAlert
    var large: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(alertEmoji(alert.label))
                .font(.system(size: large ? 18 : 15))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    SeverityDot(severity: alert.severity)
                    Text(titleizeWidget(alert.subLabel ?? alert.label))
                        .font(.system(size: large ? 13 : 12, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Text("\(titleizeWidget(alert.camera)) · \(relativeShort(alert.when))")
                    .font(.system(size: large ? 11 : 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AllClearCompact: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No recent activity")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Text("You're all clear")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
    }
}

private struct AllClearLarge: View {
    var body: some View {
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
    }
}

private struct SeverityChip: View {
    let severity: String
    let when: Date

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(severityColor(severity))
                .frame(width: 6, height: 6)
            Text(relativeShort(when))
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(
            Capsule().strokeBorder(severityColor(severity).opacity(0.8), lineWidth: 1)
        )
    }
}

private struct SeverityDot: View {
    let severity: String

    var body: some View {
        Circle()
            .fill(severityColor(severity))
            .frame(width: 7, height: 7)
    }
}

// MARK: - Lock screen

private struct AccessoryRectangularView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        if let alert = entry.latest {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(alertEmoji(alert.label)) \(titleizeWidget(alert.subLabel ?? alert.label))")
                    .font(.system(size: 14, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .widgetAccentable()
                Text(titleizeWidget(alert.camera))
                    .font(.system(size: 12, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(secondaryLine(alert))
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.85)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Label("All clear", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 14, weight: .black))
                Text("No recent alerts")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "3m ago · Driveway" — time, plus the zone when we have one.
    private func secondaryLine(_ alert: SharedAlert) -> String {
        var parts = [relativeShort(alert.when)]
        if let zone = alert.zone, !zone.isEmpty {
            parts.append(titleizeWidget(zone))
        }
        return parts.joined(separator: " · ")
    }
}

private struct AccessoryInlineView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        if let alert = entry.latest {
            Text("\(alertEmoji(alert.label)) \(titleizeWidget(alert.subLabel ?? alert.label)) · \(relativeShort(alert.when))")
        } else {
            Text("All clear")
        }
    }
}

/// Circular Lock Screen / StandBy widget: the latest detection's glyph + how long ago,
/// or a clear shield when there's nothing. Tiny, so it stays to one glyph + one line.
private struct AccessoryCircularView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let alert = entry.latest {
                VStack(spacing: 0) {
                    Text(alertEmoji(alert.label))
                        .font(.system(size: 19))
                    // Compact static form ("3m") — `.relative` renders longer phrasing that
                    // truncates/illegibly shrinks in this tiny circular tile.
                    Text(relativeShort(alert.when))
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 20, weight: .black))
                    .widgetAccentable()
            }
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
        .configurationDisplayName("ApexSight Activity")
        .description("A snapshot of your latest detection plus a recent-activity feed from your cameras.")
        .supportedFamilies(supportedFamilies)
        // Let the hero snapshot bleed edge-to-edge instead of sitting inside WidgetKit's
        // default ~16pt content inset (the text overlays pad themselves).
        .contentMarginsDisabled()
    }

    // systemExtraLarge only exists on iPad — gating it keeps the iPhone picker clean.
    private var supportedFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline, .accessoryCircular
        ]
        if UIDevice.current.userInterfaceIdiom == .pad {
            families.append(.systemExtraLarge)
        }
        return families
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
