import AVKit
import SwiftUI

struct ReviewDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let review: FrigateReviewItem

    @State private var showReviewedConfirmation = false
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                timelineCard
                objectsCard
                actionsCard
            }
            .padding(18)
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Mark this review as handled?",
            isPresented: $showReviewedConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mark Reviewed") {
                Task { await markReviewed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates your Frigate review state for this alert.")
        }
    }

    private var hero: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                if let url = appState.client?.reviewHLSURL(review: review) {
                    VideoPlayer(player: AVPlayer(playerItem: appState.client?.playerItem(for: url)))
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else if let url = appState.client?.latestFrameURL(camera: review.camera) {
                    RemoteImage(url: url)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(NotificationCopy.title(for: review))
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundStyle(GlassTheme.primary)
                            .lineLimit(2)

                        Text(NotificationCopy.body(for: review))
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                    }

                    Spacer()

                    severityBadge
                }
            }
        }
    }

    private var timelineCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Timeline")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                HStack(spacing: 10) {
                    timelineMetric("Start", value: timestamp(review.startTime), icon: "play.fill", tint: GlassTheme.green)
                    timelineMetric("End", value: timestamp(review.endTime), icon: "stop.fill", tint: GlassTheme.orange)
                    timelineMetric("Duration", value: duration, icon: "timer", tint: GlassTheme.cyan)
                }
            }
        }
    }

    private var objectsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Detected")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                tagSection(title: "Objects", values: review.data?.objects ?? [])
                tagSection(title: "Zones", values: review.data?.zones ?? [])
                tagSection(title: "Audio", values: review.data?.audio ?? [])
            }
        }
    }

    private var actionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Actions")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                Button {
                    showReviewedConfirmation = true
                } label: {
                    Label("Mark Reviewed", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.green))
                .disabled(isWorking)

                if let camera = appState.cameras.first(where: { $0.name == review.camera }) {
                    NavigationLink {
                        GlassCard {
                            CameraCard(camera: camera)
                                .padding(8)
                        }
                        .padding(18)
                        .navigationTitle(titleize(camera.name))
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Open Camera", systemImage: "video.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.blue))
                }
            }
        }
    }

    private var severityBadge: some View {
        Text(titleize(review.severity ?? "activity"))
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background((review.severity == "alert" ? GlassTheme.orange : GlassTheme.cyan), in: Capsule())
    }

    private var duration: String {
        guard let start = review.startTime, let end = review.endTime else { return "n/a" }
        let seconds = max(0, Int(end - start))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func markReviewed() async {
        isWorking = true
        await appState.markReviewViewed(review)
        isWorking = false
        dismiss()
    }

    private func timelineMetric(_ title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(GlassTheme.secondary)
            Text(value)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(GlassTheme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func tagSection(title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(GlassTheme.secondary)

                FlowTags(values: values)
            }
        }
    }

    private func timestamp(_ epoch: Double?) -> String {
        guard let epoch else { return "n/a" }
        return Date(timeIntervalSince1970: epoch).formatted(date: .omitted, time: .shortened)
    }
}

struct FlowTags: View {
    let values: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    tag(value)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(values, id: \.self) { value in
                    tag(value)
                }
            }
        }
    }

    private func tag(_ value: String) -> some View {
        Text(titleize(value))
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(GlassTheme.cyan)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(GlassTheme.cyan.opacity(0.14), in: Capsule())
    }
}
