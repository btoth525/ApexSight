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
        // The widget gallery must not hit the network — scrolling it fired a latest.jpg per size.
        if context.isPreview { return placeholder(in: context) }
        return await makeEntry(for: configuration, wantsImage: Self.isSystemFamily(context.family))
    }

    func timeline(for configuration: SelectCameraIntent, in context: Context) async -> Timeline<SelectedCameraEntry> {
        // Pull fresh alerts straight from Frigate so this widget (including the Lock Screen
        // accessory families) updates on its OWN WidgetKit schedule — not only when the app is
        // opened or a push arrives. Mirrors the home-screen widget's self-refresh.
        if WidgetDataFetcher.recentAlertsAge > 90 { await WidgetDataFetcher.refresh() }
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
        // Frigate resizes on the server (`height=`, measured on 0.18): ~40 KB instead of a
        // full-resolution frame (~1.5 MB for a 4K camera) per timeline per widget instance, and
        // nothing near the widget process's ~30 MB ceiling ever gets decoded.
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/\(camera)/latest.jpg"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "height", value: "480")]
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let token = SharedTokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("frigate_token=\(token)", forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await BoundedSession.widget.data(for: request),
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
        // No `UIImage(data:)` fallback: that decodes the WHOLE frame lazily at render time inside
        // the widget process — a 4K frame is ~33 MB, past the ~30 MB cap → jetsam → blank widget.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
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
                Text(activity(a)).font(.caption).lineLimit(1).privacySensitive()
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
                    Image(systemName: labelSymbol(a.label)).font(.system(size: 10, weight: .bold))
                }
            }
        }
        .widgetURL(deepLink)
    }

    // MARK: - Home screen (snapshot)

    private var systemView: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = entry.image {
                if #available(iOS 18.0, *) {
                    Image(uiImage: image)
                        .resizable()
                        .widgetAccentedRenderingMode(.fullColor)   // a tinted Home Screen must not silhouette the frame
                        .scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(WidgetCameraEntity.titleize(name))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    // A frame with no time reads as live; this one may be 15 minutes old.
                    (Text("Updated ") + Text(entry.date, style: .relative) + Text(" ago"))
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
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

    /// SF Symbols, not emoji: the accessory families render vibrant/accented, where emoji smudge.
    private func labelSymbol(_ label: String) -> String {
        switch label.lowercased() {
        case "person": return "figure.walk"
        case "car", "truck": return "car.fill"
        case "dog": return "dog.fill"
        case "cat": return "cat.fill"
        case "package": return "shippingbox.fill"
        default: return "video.fill"
        }
    }

    private var deepLink: URL? {
        guard let name = entry.cameraName else { return URL(string: "apex://") }
        // `latest.id` is a REVIEW id, so route to apex://review (apex://event does an event-id
        // lookup that fails for a review id → dead tap + wrong tab). Percent-encode it.
        if let id = entry.latest?.id {
            let eid = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
            return URL(string: "apex://review?id=\(eid)")
        }
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
