import AVFoundation
import AVKit
import SwiftUI

struct ReviewDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let review: FrigateReviewItem

    @State private var showReviewedConfirmation = false
    @State private var isWorking = false
    @State private var reviewPlayer: AVPlayer?
    @State private var mediaMode: MediaMode = .video
    @State private var detectionEvents: [FrigateEvent] = []
    @State private var loadingDetections = false

    private enum MediaMode: String, CaseIterable {
        case video = "Video"
        case snapshot = "Snapshot"
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    timelineCard
                    objectsCard
                    actionsCard
                }
                .padding(18)
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task {
            guard reviewPlayer == nil, let client = appState.client else { return }
            // Play the recording spanning the review's time range — this is the same
            // endpoint the timeline uses and works reliably on stock Frigate. The
            // `/api/review/{id}/clip.mp4` path does not exist on stock Frigate.
            guard let start = review.startTime else { return }
            let end = review.endTime ?? (start + 20)
            let url = client.recordingClipURL(camera: review.camera, start: start, end: end)
            let item = client.playerItem(for: url)
            let player = AVPlayer(playerItem: item)
            reviewPlayer = player
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()   // auto-play the review clip (direct MP4)
        }
        .onDisappear { reviewPlayer?.pause() }
        .task(id: review.id) {
            guard let client = appState.client else { return }
            loadingDetections = true
            var loaded: [FrigateEvent] = []
            for id in review.data?.detections ?? [] {
                if let event = try? await client.event(id: id) {
                    loaded.append(event)
                }
            }
            detectionEvents = loaded
            loadingDetections = false
        }
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
            VStack(alignment: .leading, spacing: 12) {
                Picker("Media", selection: $mediaMode) {
                    ForEach(MediaMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mediaMode) { _, mode in
                    if mode == .video { reviewPlayer?.play() } else { reviewPlayer?.pause() }
                }

                ZStack {
                    if mediaMode == .video, let reviewPlayer {
                        PiPPlayerView(player: reviewPlayer)
                            .frame(height: 230)
                            .frame(maxWidth: .infinity)
                    } else if let url = snapshotURL {
                        ZoomableScrollView {
                            RemoteImage(url: url, contentMode: .fit)
                        }
                        .frame(height: 230)
                        .frame(maxWidth: .infinity)
                    } else {
                        Color.black
                            .frame(height: 230)
                            .frame(maxWidth: .infinity)
                    }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NotificationCopy.title(for: review))
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(GlassTheme.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Text(NotificationCopy.body(for: review))
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    severityBadge
                }
            }
        }
    }

    private var snapshotURL: URL? {
        appState.client?.reviewSnapshotURL(review: review)
            ?? appState.client?.reviewThumbnailURL(review: review)
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

                if !detectionEvents.isEmpty || loadingDetections {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DETECTIONS")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(GlassTheme.secondary)
                        if loadingDetections {
                            ProgressView().tint(GlassTheme.cyan)
                        } else {
                            VStack(spacing: 6) {
                                ForEach(detectionEvents) { event in
                                    NavigationLink(value: event) {
                                        HStack(spacing: 10) {
                                            if let url = appState.client?.eventThumbnailURL(id: event.id) {
                                                RemoteImage(url: url)
                                                    .frame(width: 48, height: 48)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                                                    .font(.system(size: 14, weight: .black))
                                                    .foregroundStyle(GlassTheme.primary)
                                                if let epoch = event.startTime {
                                                    Text(Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened))
                                                        .font(.system(size: 11, weight: .bold))
                                                        .foregroundStyle(GlassTheme.secondary)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(GlassTheme.tertiary)
                                        }
                                        .padding(8)
                                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
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
                        LiveStreamView(camera: camera)
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
