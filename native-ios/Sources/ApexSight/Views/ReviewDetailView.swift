import AVFoundation
import AVKit
import SwiftUI

struct ReviewDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let review: FrigateReviewItem

    @State private var showReviewedConfirmation = false
    @State private var isWorking = false
    @StateObject private var clipModel = ClipPlayerModel()
    @State private var mediaMode: MediaMode = .video
    @State private var detectionEvents: [FrigateEvent] = []
    @State private var loadingDetections = false
    @State private var reviewAIDescription: String?
    /// Distinguishes "no summary" from "still fetching", so the AI card can show a skeleton
    /// on first load instead of silently appearing only once text arrives.
    @State private var isLoadingAIDescription = true

    private enum MediaMode: String, CaseIterable {
        case video = "Video"
        case snapshot = "Snapshot"
        case history = "History"
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    hero
                    if let reviewAIDescription {
                        aiCard(reviewAIDescription)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if isLoadingAIDescription {
                        aiSkeletonCard
                    }
                    timelineCard
                    objectsCard
                    actionsCard
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task(id: review.id) {
            guard let client = appState.client, let start = review.startTime else { clipModel.stop(); return }
            let end = review.endTime ?? (start + 20)
            // Force a (re)load keyed to THIS review so a reused detail view can never
            // show the previous review's clip. VOD HLS for the review's time range —
            // Frigate's documented, iOS-recommended recording source.
            clipModel.load(
                client: client,
                url: client.recordingHLSURL(camera: review.camera, start: start, end: end)
            )
        }
        .onDisappear { clipModel.stop() }
        .task(id: review.id) {
            guard let client = appState.client else { return }
            // Reset prior review's data so a reused view doesn't show review A's summary +
            // detections under review B's header until B loads.
            reviewAIDescription = nil
            detectionEvents = []
            isLoadingAIDescription = true
            let fetched = try? await client.reviewDescription(id: review.id)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                reviewAIDescription = fetched
                isLoadingAIDescription = false
            }
            let ids = review.data?.detections ?? []
            guard !ids.isEmpty else { return }
            loadingDetections = true
            var loaded: [FrigateEvent] = []
            await withTaskGroup(of: FrigateEvent?.self) { group in
                for id in ids { group.addTask { try? await client.event(id: id) } }
                for await event in group { if let event { loaded.append(event) } }
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                detectionEvents = loaded.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
                loadingDetections = false
            }
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
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                Picker("Media", selection: $mediaMode) {
                    ForEach(MediaMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mediaMode) { _, mode in
                    Haptics.select()
                    if mode == .video { clipModel.play() } else { clipModel.pause() }
                }

                ZStack {
                    if mediaMode == .video {
                        // Holds a loading skeleton until a real frame is ready, then fades the
                        // clip in — never a black box.
                        LoadingClipPlayer(model: clipModel)
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                    } else if mediaMode == .history, let startTime = review.startTime {
                        RecordingContextPlayerView(
                            camera: review.camera,
                            centerTime: startTime,
                            eventStart: review.startTime,
                            eventEnd: review.endTime
                        )
                        .frame(maxWidth: .infinity)
                    } else if let url = snapshotURL {
                        ZoomableScrollView {
                            RemoteImage(url: url, contentMode: .fit)
                        }
                        .frame(height: 300)
                        .frame(maxWidth: .infinity)
                    } else if let url = appState.client?.latestFrameURL(camera: review.camera) {
                        // No event snapshot — show the camera's latest frame, never a black box.
                        RemoteImage(url: url, contentMode: .fit)
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                    } else {
                        Color.black
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                    }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
                .expandableMedia(fullscreenMedia)

                HStack(alignment: .top, spacing: GlassTheme.Space.m) {
                    VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                        Text(NotificationCopy.title(for: review))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(GlassTheme.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Text(NotificationCopy.body(for: review))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(GlassTheme.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    severityBadge
                }
            }
        }
    }

    private func aiCard(_ text: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                    Text("AI Summary")
                        .font(.headline)
                        .foregroundStyle(GlassTheme.primary)
                }
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(GlassTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Skeleton shown while the review's AI summary is being fetched, so the card keeps its
    /// shape instead of popping in only once text arrives.
    private var aiSkeletonCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                    Text("AI Summary")
                        .font(.headline)
                        .foregroundStyle(GlassTheme.primary)
                }
                SkeletonBlock().frame(height: 13).frame(maxWidth: .infinity, alignment: .leading)
                SkeletonBlock().frame(width: 200, height: 13)
            }
        }
        .accessibilityLabel("Loading AI summary")
    }

    private var snapshotURL: URL? {
        appState.client?.reviewSnapshotURL(review: review)
            ?? appState.client?.reviewThumbnailURL(review: review)
    }

    /// What the fullscreen viewer shows — it MUST mirror exactly what the hero renders
    /// inline, so expand never opens the wrong medium (a snapshot while watching the
    /// clip, or vice-versa) and the history scrubber isn't replaced by a still.
    private var fullscreenMedia: FullscreenMediaView.Media? {
        switch mediaMode {
        case .video:
            // The clip is expandable to the zoomable video. While it's still loading
            // (no player yet) hide the button rather than fall back to the snapshot.
            guard let player = clipModel.player else { return nil }
            return .player(player)
        case .snapshot:
            guard let url = snapshotURL else { return nil }
            return .image(url)
        case .history:
            // The history scrubber has its own controls; nothing to expand.
            return nil
        }
    }

    private var timelineCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Timeline")

                HStack(spacing: GlassTheme.Space.s) {
                    timelineMetric("Start", value: timestamp(review.startTime), icon: "play.fill", tint: GlassTheme.green)
                    timelineMetric("End", value: timestamp(review.endTime), icon: "stop.fill", tint: GlassTheme.orange)
                    timelineMetric("Duration", value: duration, icon: "timer", tint: GlassTheme.accent)
                }
            }
        }
    }

    private var objectsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Detected")

                tagSection(title: "Objects", values: review.data?.objects ?? [])
                tagSection(title: "Zones", values: review.data?.zones ?? [])
                tagSection(title: "Audio", values: review.data?.audio ?? [])

                if !detectionEvents.isEmpty || loadingDetections {
                    VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                        Text("Detections".uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GlassTheme.tertiary)
                        if loadingDetections {
                            // A couple of skeleton rows matching the detection layout, so the
                            // section keeps its shape instead of a lone spinner.
                            VStack(spacing: GlassTheme.Space.s) {
                                ForEach(0..<2, id: \.self) { _ in detectionSkeletonRow }
                            }
                        } else {
                            VStack(spacing: GlassTheme.Space.s) {
                                ForEach(detectionEvents) { event in
                                    NavigationLink(value: event) {
                                        HStack(spacing: GlassTheme.Space.m) {
                                            if let url = appState.client?.eventThumbnailURL(id: event.id) {
                                                RemoteImage(url: url, maxPixelSize: 150)
                                                    .frame(width: 48, height: 48)
                                                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
                                            }
                                            VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                                                Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(GlassTheme.primary)
                                                if let epoch = event.startTime {
                                                    Text(Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened))
                                                        .font(.footnote.weight(.medium))
                                                        .foregroundStyle(GlassTheme.secondary)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(GlassTheme.tertiary)
                                        }
                                        .padding(GlassTheme.Space.s)
                                        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                                        .cardStroke(GlassTheme.Radius.tile)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityElement(children: .combine)
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
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Actions")

                Button {
                    Haptics.tap()
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
        let tint = review.severity == "alert" ? GlassTheme.orange : GlassTheme.accent
        return Text(titleize(review.severity ?? "activity"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, GlassTheme.Space.xs)
            .background(tint.opacity(0.14), in: Capsule())
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
        Haptics.success()
        isWorking = false
        dismiss()
    }

    /// One skeleton row mirroring a detection row (thumbnail + two text lines).
    private var detectionSkeletonRow: some View {
        HStack(spacing: GlassTheme.Space.m) {
            SkeletonBlock(cornerRadius: GlassTheme.Radius.chip)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                SkeletonBlock().frame(width: 130, height: 13)
                SkeletonBlock().frame(width: 90, height: 11)
            }
            Spacer(minLength: 0)
        }
        .padding(GlassTheme.Space.s)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
        .cardStroke(GlassTheme.Radius.tile)
        .accessibilityHidden(true)
    }

    private func timelineMetric(_ title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GlassTheme.tertiary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GlassTheme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GlassTheme.Space.m)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
        .cardStroke(GlassTheme.Radius.tile)
    }

    @ViewBuilder
    private func tagSection(title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GlassTheme.tertiary)

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
            HStack(spacing: GlassTheme.Space.s) {
                ForEach(values, id: \.self) { value in
                    tag(value)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: GlassTheme.Space.s)], spacing: GlassTheme.Space.s) {
                ForEach(values, id: \.self) { value in
                    tag(value)
                }
            }
        }
    }

    private func tag(_ value: String) -> some View {
        Text(titleize(value))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(GlassTheme.accent)
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, GlassTheme.Space.s)
            .background(GlassTheme.accent.opacity(0.12), in: Capsule())
    }
}
