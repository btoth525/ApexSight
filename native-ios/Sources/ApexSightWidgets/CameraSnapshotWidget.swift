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
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryInline:
            CameraSnapshotLockScreenView(entry: entry)
                .containerBackground(.thinMaterial, for: .widget)
                .widgetURL(widgetURL)
        default:
            mainWidgetBody
                .containerBackground(.thinMaterial, for: .widget)
                .widgetURL(widgetURL)
        }
    }

    private var widgetURL: URL? {
        guard let camera = entry.snapshot?.camera.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return URL(string: "apex://")
        }
        return URL(string: "apex://camera?name=\(camera)")
    }

    private var mainWidgetBody: some View {
        let age = entry.snapshot.map { Int(Date().timeIntervalSince($0.capturedAt) / 60) } ?? 0
        let freshText = age == 0 ? "Just now" : "\(age)m ago"
        return ZStack(alignment: .bottomLeading) {
            snapshotImage

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Label(entry.snapshot.map { titleizeWidget($0.camera) } ?? "ApexSight", systemImage: "video.fill")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .lineLimit(1)

                Text(entry.snapshot.map { "\($0.serverName) · \(freshText)" } ?? "Open app to cache a snapshot")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(14)

            // Freshness badge
            if let snapshot = entry.snapshot {
                VStack {
                    HStack {
                        Spacer()
                        Text(age == 0 ? "LIVE" : "\(age)m")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(age > 5 ? Color.orange : Color.green, in: Capsule())
                            .padding(10)
                    }
                    Spacer()
                }
                .opacity(snapshot.camera.isEmpty ? 0 : 1)
            }
        }
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
                VStack(spacing: 8) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("ApexSight")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }
}

struct CameraSnapshotLockScreenView: View {
    let entry: CameraSnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .black))
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleizeWidget(snapshot.camera))
                        .font(.system(size: 12, weight: .black))
                        .lineLimit(1)
                    Text(snapshot.capturedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .heavy))
                        .opacity(0.7)
                }
            }
        } else {
            Label("ApexSight", systemImage: "video.fill")
                .font(.system(size: 12, weight: .black))
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
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private func titleizeWidget(_ value: String) -> String {
    value
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}
