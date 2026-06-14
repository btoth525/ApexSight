import SwiftUI
import WidgetKit
import UIKit

struct CameraSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedCameraSnapshot?
    let imageURL: URL?
}

struct CameraSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> CameraSnapshotEntry {
        CameraSnapshotEntry(date: Date(), snapshot: nil, imageURL: nil)
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
        if let cached = SharedSnapshotStore.load() {
            return CameraSnapshotEntry(date: Date(), snapshot: cached.snapshot, imageURL: cached.imageURL)
        }
        return CameraSnapshotEntry(date: Date(), snapshot: nil, imageURL: nil)
    }
}

struct CameraSnapshotWidgetView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            snapshotImage

            LinearGradient(
                colors: [.clear, .black.opacity(0.68)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Label(entry.snapshot.map { titleizeWidget($0.camera) } ?? "ApexSight", systemImage: "video.fill")
                    .font(.system(size: 15, weight: .900, design: .rounded))
                    .lineLimit(1)

                Text(entry.snapshot.map { "\($0.serverName) - \($0.capturedAt.formatted(date: .omitted, time: .shortened))" } ?? "Open the app to cache a Frigate snapshot")
                    .font(.system(size: 11, weight: .800))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .containerBackground(.thinMaterial, for: .widget)
        .widgetURL(widgetURL)
    }

    private var widgetURL: URL? {
        guard let camera = entry.snapshot?.camera.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return URL(string: "apex://")
        }
        return URL(string: "apex://camera?name=\(camera)")
    }

    @ViewBuilder
    private var snapshotImage: some View {
        if
            let imageURL = entry.imageURL,
            let image = UIImage(contentsOfFile: imageURL.path)
        {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.10, blue: 0.14),
                        Color(red: 0.02, green: 0.03, blue: 0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "camera.aperture")
                    .font(.system(size: 38, weight: .800))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

struct CameraSnapshotWidget: Widget {
    let kind = "CameraSnapshotWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CameraSnapshotProvider()) { entry in
            CameraSnapshotWidgetView(entry: entry)
        }
        .configurationDisplayName("ApexSight Camera")
        .description("Shows the latest cached Frigate camera snapshot.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private func titleizeWidget(_ value: String) -> String {
    value
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}
