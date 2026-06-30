import WidgetKit
import SwiftUI
import UIKit
import AppIntents

/// iOS 27 A5 — a user-customizable widget. The user picks a camera (via `SelectCameraIntent`) and
/// the widget shows that camera's latest snapshot. Reuses the App-Group base URL + shared-Keychain
/// token the rest of the extension already uses; no live streaming in a widget.
struct SelectedCameraEntry: TimelineEntry {
    let date: Date
    let cameraName: String?
    let image: UIImage?
}

struct SelectedCameraProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SelectedCameraEntry {
        SelectedCameraEntry(date: Date(), cameraName: nil, image: nil)
    }

    func snapshot(for configuration: SelectCameraIntent, in context: Context) async -> SelectedCameraEntry {
        await makeEntry(for: configuration)
    }

    func timeline(for configuration: SelectCameraIntent, in context: Context) async -> Timeline<SelectedCameraEntry> {
        let entry = await makeEntry(for: configuration)
        // Refresh roughly every 15 minutes (snapshots, not live).
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date.addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func makeEntry(for configuration: SelectCameraIntent) async -> SelectedCameraEntry {
        guard let name = configuration.camera?.id else {
            return SelectedCameraEntry(date: Date(), cameraName: nil, image: nil)
        }
        let image = await SelectedCameraSnapshotFetcher.latest(camera: name)
        return SelectedCameraEntry(date: Date(), cameraName: name, image: image)
    }
}

/// Fetches a single camera's `latest.jpg` from Frigate using App-Group config + shared token —
/// the same auth path `WidgetDataFetcher` uses.
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
        return UIImage(data: data)
    }
}

struct SelectedCameraWidgetView: View {
    let entry: SelectedCameraEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
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
        .containerBackground(.black, for: .widget)
    }
}

struct SelectedCameraWidget: Widget {
    let kind = "SelectedCameraWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectCameraIntent.self, provider: SelectedCameraProvider()) { entry in
            SelectedCameraWidgetView(entry: entry)
        }
        .configurationDisplayName("ApexSight Camera")
        .description("A snapshot of a camera you choose. Long-press to pick the camera.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
