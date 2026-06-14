import SwiftUI
import AVKit

struct EventDetailView: View {
    @EnvironmentObject private var appState: AppState
    let event: FrigateEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        if let url = appState.client?.eventSnapshotURL(id: event.id) {
                            RemoteImage(url: url)
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }

                        Text(titleize(event.label))
                            .font(.system(size: 28, weight: .900, design: .rounded))
                            .foregroundStyle(GlassTheme.primary)

                        Text("\(titleize(event.camera)) - \(timestamp(event.startTime))")
                            .font(.system(size: 14, weight: .800))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Details")
                            .font(.system(size: 21, weight: .900))
                            .foregroundStyle(GlassTheme.primary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            metric("Confidence", value: confidence)
                            metric("Camera", value: titleize(event.camera))
                            metric("Clip", value: event.hasClip == false ? "No" : "Available")
                            metric("Snapshot", value: event.hasSnapshot == false ? "No" : "Available")
                        }

                        if let zones = event.zones, !zones.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(zones, id: \.self) { zone in
                                        Text(titleize(zone))
                                            .font(.system(size: 12, weight: .900))
                                            .foregroundStyle(GlassTheme.cyan)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(GlassTheme.cyan.opacity(0.14), in: Capsule())
                                    }
                                }
                            }
                        }
                    }
                }

                if let clipURL = appState.client?.eventHLSURL(id: event.id), event.hasClip != false {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Clip")
                                .font(.system(size: 21, weight: .900))
                                .foregroundStyle(GlassTheme.primary)
                            VideoPlayer(player: AVPlayer(playerItem: appState.client?.playerItem(for: clipURL)))
                                .frame(height: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                }
            }
            .padding(18)
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var confidence: String {
        guard let score = event.score ?? event.topScore else { return "n/a" }
        return "\(Int(score * 100))%"
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .900))
                .foregroundStyle(GlassTheme.secondary)
            Text(value)
                .font(.system(size: 15, weight: .900))
                .foregroundStyle(GlassTheme.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func timestamp(_ epoch: Double?) -> String {
        guard let epoch else { return "Live" }
        return Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened)
    }
}
