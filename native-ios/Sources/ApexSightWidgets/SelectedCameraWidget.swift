import WidgetKit
import SwiftUI
import UIKit
import ImageIO
import AppIntents

/// iOS 27 A5 — a user-customizable camera widget. Pick a camera (via `SelectCameraIntent`); the
/// home-screen sizes show its latest snapshot, and the LOCK-SCREEN (accessory) sizes show that
/// camera's most recent activity as a glance. Updates live on every push (the notification service
/// reloads widget timelines). Reuses the App-Group base URL + shared-Keychain token.
struct SelectedCameraEntry: TimelineEntry {
    let date: Date
    let cameraName: String?
    let image: UIImage?
    let latest: SharedAlert?   // most recent activity for the chosen camera (lock-screen glance)
}

struct SelectedCameraProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SelectedCameraEntry {
        SelectedCameraEntry(date: Date(), cameraName: nil, image: nil, latest: nil)
    }

    func snapshot(for configuration: SelectCameraIntent, in context: Context) async -> SelectedCameraEntry {
        await makeEntry(for: configuration, wantsImage: Self.isSystemFamily(context.family))
    }

    func timeline(for configuration: SelectCameraIntent, in context: Context) async -> Timeline<SelectedCameraEntry> {
        // Pull fresh alerts straight from Frigate so this widget (including the Lock Screen
        // accessory families) updates on its OWN WidgetKit schedule — not only when the app is
        // opened or a push arrives. Mirrors the home-screen widget's self-refresh.
        await WidgetDataFetcher.refresh()
        let entry = await makeEntry(for: configuration, wantsImage: Self.isSystemFamily(context.family))
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date.addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(next))
    }

    /// Lock-screen (accessory) sizes don't render photos — skip the snapshot fetch there to save
    /// the widget's memory/time budget; they only need the latest-activity glance.
    private static func isSystemFamily(_ family: WidgetFamily) -> Bool {
        switch family {
        case .accessoryInline, .accessoryRectangular, .accessoryCircular: return false
        default: return true
        }
    }

    private func makeEntry(for configuration: SelectCameraIntent, wantsImage: Bool) async -> SelectedCameraEntry {
        guard let name = configuration.camera?.id else {
            return SelectedCameraEntry(date: Date(), cameraName: nil, image: nil, latest: nil)
        }
        let latest = SharedSnapshotStore.loadRecentAlerts().alerts
            .filter { $0.camera == name }
            .max { $0.when < $1.when }
        let image = wantsImage ? await SelectedCameraSnapshotFetcher.latest(camera: name) : nil
        return SelectedCameraEntry(date: Date(), cameraName: name, image: image, latest: latest)
    }
}

/// Fetches a single camera's `latest.jpg` from Frigate using App-Group config + shared token.
enum SelectedCameraSnapshotFetcher {
    static func latest(camera: String) async -> UIImage? {
        guard let defaults = UserDefaults(suiteName: ApexAppGroup.identifier),
              let base = defaults.string(forKey: "apex.frigateBaseURL"),
              let baseURL = URL(string: base) else { return nil }
        let url = baseURL.appendingPathComponent("api/\(camera)/latest.jpg")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let token = SharedTokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("frigate_token=\(token)", forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return downsampled(data, maxPixel: 900)
    }

    private static func downsampled(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }
}

struct SelectedCameraWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SelectedCameraEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(inlineText, systemImage: "video.fill")
        case .accessoryRectangular:
            rectangularView.containerBackground(.clear, for: .widget)
        case .accessoryCircular:
            circularView.containerBackground(.clear, for: .widget)
        default:
            systemView.containerBackground(.black, for: .widget)
        }
    }

    // MARK: - Lock screen (accessory)

    private var inlineText: String {
        guard let name = entry.cameraName else { return "Pick a camera" }
        if let a = entry.latest { return "\(WidgetCameraEntity.titleize(name)) · \(activity(a))" }
        return "\(WidgetCameraEntity.titleize(name)) · Clear"
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "video.fill").font(.caption2)
                Text(entry.cameraName.map(WidgetCameraEntity.titleize) ?? "Pick a Camera")
                    .font(.headline).lineLimit(1)
            }
            if let a = entry.latest {
                Text(activity(a)).font(.caption).lineLimit(1)
                Text(a.when, style: .relative).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(entry.cameraName == nil ? "Hold to choose" : "No recent activity")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(deepLink)
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: entry.latest != nil ? "video.badge.waveform" : "video.fill")
                    .font(.system(size: 15, weight: .semibold))
                if let a = entry.latest {
                    Text(labelEmoji(a.label)).font(.system(size: 10))
                }
            }
        }
        .widgetURL(deepLink)
    }

    // MARK: - Home screen (snapshot)

    private var systemView: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = entry.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.black
                VStack(spacing: 6) {
                    Image(systemName: entry.cameraName == nil ? "rectangle.dashed" : "video.slash.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(entry.cameraName == nil ? "Hold → Edit Widget\nto pick a camera" : "No snapshot yet")
                        .font(.system(size: 11, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let name = entry.cameraName {
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                Text(WidgetCameraEntity.titleize(name))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .padding(10)
            }
        }
        .widgetURL(deepLink)
    }

    // MARK: - Helpers

    private func activity(_ a: SharedAlert) -> String {
        let subject = (a.subLabel?.isEmpty == false) ? a.subLabel! : a.label
        return WidgetCameraEntity.titleize(subject)
    }

    private func labelEmoji(_ label: String) -> String {
        switch label.lowercased() {
        case "person": return "🧍"
        case "car", "truck": return "🚗"
        case "dog": return "🐕"
        case "cat": return "🐈"
        case "package": return "📦"
        default: return "📹"
        }
    }

    private var deepLink: URL? {
        guard let name = entry.cameraName else { return URL(string: "apex://") }
        if let id = entry.latest?.id { return URL(string: "apex://event?id=\(id)") }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return URL(string: "apex://camera?name=\(encoded)")
    }
}

struct SelectedCameraWidget: Widget {
    let kind = "SelectedCameraWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectCameraIntent.self, provider: SelectedCameraProvider()) { entry in
            SelectedCameraWidgetView(entry: entry)
        }
        .configurationDisplayName("ApexSight Camera")
        .description("A camera you choose — a snapshot on the Home Screen, its latest activity on the Lock Screen. Long-press to pick the camera.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}
