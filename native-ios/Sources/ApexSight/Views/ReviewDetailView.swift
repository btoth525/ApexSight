import AVFoundation
import AVKit
import SwiftUI

struct ReviewDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let review: FrigateReviewItem

    @State private var showReviewedConfirmation = false
    @State private var isWorking = false
    @State private var mediaMode: MediaMode = .snapshot
    @State private var highlightTS: Double?
    @State private var trackingBeats: [TimelineBeat] = []
    @State private var loadingTracking = false
    /// True while our fullscreen media cover is presented — onDisappear must NOT stop the
    /// clip player then (the cover is displaying that very player).
    @State private var mediaExpanded = false
    @State private var detectionEvents: [FrigateEvent] = []
    /// Set only when this review's own snapshot belongs to a different moment (`ReviewStillPolicy`).
    @State private var pinnedStill: URL?
    @State private var loadingDetections = false
    /// Frigate's review API has no `description` field (measured: /api/review and
    /// /api/review/<id> return id, camera, start/end_time, severity, thumb_path,
    /// has_been_reviewed, data — nothing else), so this is populated purely from the payload the
    /// list already carries. It stays wired so a future Frigate that does emit one renders it.
    private var reviewAIDescription: String? {
        let text = review.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    private enum MediaMode: String, CaseIterable {
        case snapshot = "Snapshot"
        case tracking = "Tracking"
        case history  = "History"
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    hero
                    if mediaMode == .tracking { trackingCard }
                    // Frigate's review-level GenAI story sits directly under the clip: it answers
                    // "should I care about this one", which is the question you have while the
                    // video is still playing. The per-object description below answers the
                    // different question "who was that", so it stays after it.
                    if let summary = review.data?.metadata, summary.hasContent {
                        ReviewStoryCard(summary: summary, objects: review.data?.objects ?? [])
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                    if let reviewAIDescription {
                        aiCard(reviewAIDescription)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
            // Object lifecycle timeline for the Tracking tab (primary detection; [] hides the rail).
            highlightTS = nil
            trackingBeats = []
            guard let pid = FrigateClient.primaryDetectionID(of: review), let client = appState.client else { return }
            loadingTracking = true
            trackingBeats = await client.objectTimeline(eventID: pid)
            loadingTracking = false
        }
        // Same rule as `ReviewRow`: re-ask while the review is live, once more when it ends.
        .task(id: "\(review.id)|\(review.endTime == nil)") {
            pinnedStill = nil
            pinnedStill = await ReviewStillResolver.shared.pinnedStill(for: review,
                                                                       client: appState.client)
        }
        .task(id: review.id) {
            guard let client = appState.client else { return }
            // Reset prior review's detections so a reused view doesn't show review A's
            // detections under review B's header until B loads.
            detectionEvents = []
            let ids = review.data?.detections ?? []
            guard !ids.isEmpty else { return }
            loadingDetections = true
            var loaded: [FrigateEvent] = []
            await withTaskGroup(of: FrigateEvent?.self) { group in
                for id in ids { group.addTask { try? await client.event(id: id) } }
                for await event in group { if let event { loaded.append(event) } }
            }
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
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
                .onChange(of: mediaMode) { _, _ in Haptics.select() }

                ZStack {
                    switch mediaMode {
                    case .snapshot:
                        // Best CROPPED image of what was found (the primary detection), review
                        // thumbnail as the always-available fallback.
                        if let pid = FrigateClient.primaryDetectionID(of: review),
                           let url = appState.client?.eventBestCropURL(id: pid, height: 1080) {
                            RemoteImage(url: url, contentMode: .fit, maxPixelSize: 1600, revalidate: review.endTime == nil,
                                        fallbackURL: appState.client?.reviewThumbnailURL(review: review))
                                .snapshotFrame()
                        } else if let url = snapshotURL {
                            RemoteImage(url: url, contentMode: .fit, maxPixelSize: 1600, revalidate: review.endTime == nil,
                                        fallbackURL: appState.client?.reviewThumbnailURL(review: review))
                                .snapshotFrame()
                        } else { mediaPlaceholder }
                    case .tracking:
                        // Clean full frame + tail. Tapping a lifecycle beat swaps to the RECORDED
                        // frame at that moment and boxes the object where it was.
                        if let url = trackingFrameURL {
                            TrackedSnapshot(url: url, fill: true, focus: trackingFocus) { size in
                                ZStack {
                                    PathTailCanvas(points: primaryEvent?.pathData ?? [],
                                                   snapshotTS: primaryEvent?.snapshotFrameTime,
                                                   highlightTS: trackingHighlightTS, size: size)
                                    if let box = trackingBox {
                                        BeatBoxView(box: box, size: size, label: primaryEvent?.displayLabel, score: selectedBeat?.score)
                                            .id(selectedBeat?.ts)
                                    }
                                }
                            }
                            .trackingFrame()
                        } else { mediaPlaceholder }
                    case .history:
                        if let startTime = review.startTime {
                            RecordingContextPlayerView(camera: review.camera, centerTime: startTime,
                                                       eventStart: review.startTime, eventEnd: review.endTime,
                                                       frameAspect: mediaAspect)
                                .frame(maxWidth: .infinity)
                        } else if let url = snapshotURL {
                            RemoteImage(url: url, contentMode: .fit).mediaAspectFrame(mediaAspect)
                        } else { mediaPlaceholder }
                    }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
                .expandableMedia(fullscreenMedia, isPresented: $mediaExpanded)

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

    /// The object's own snapshot — right for most reviews, and the fallback when a pinned
    /// recording frame can't be served.
    private var objectStillURL: URL? {
        appState.client?.reviewSnapshotURL(review: review)
            ?? appState.client?.reviewThumbnailURL(review: review)
    }

    private var snapshotURL: URL? { pinnedStill ?? objectStillURL }

    /// What the fullscreen viewer shows — it MUST mirror exactly what the hero renders
    /// inline, so expand never opens the wrong medium (a snapshot while watching the
    /// clip, or vice-versa) and the history scrubber isn't replaced by a still.
    private var fullscreenMedia: FullscreenMediaView.Media? {
        switch mediaMode {
        case .snapshot:
            guard let url = snapshotURL else { return nil }
            return .image(url)
        case .tracking:
            // Maximize keeps the tail + path (and the selected-beat box) and zooms it all together.
            guard let url = trackingFrameURL else { return nil }
            return .tracked(url: url, points: primaryEvent?.pathData ?? [], snapshotTS: primaryEvent?.snapshotFrameTime,
                            highlightTS: trackingHighlightTS, box: trackingBox,
                            label: primaryEvent?.displayLabel, score: selectedBeat?.score)
        case .history:
            return nil
        }
    }

    private var primaryEvent: FrigateEvent? {
        // Strictly the primary detection: if it isn't loaded yet, show NO tail rather than
        // drawing a different object's path over the primary detection's frame. The clean
        // snapshot (keyed to `pid` directly) still renders; the tail fills in once loaded.
        guard let pid = FrigateClient.primaryDetectionID(of: review) else { return detectionEvents.first }
        return detectionEvents.first(where: { $0.id == pid })
    }

    /// The camera's true frame aspect — drives every media tab's height so ultra-wide / fisheye
    /// feeds fill without black bars and all three tabs read as one surface.
    private var mediaAspect: CGFloat {
        appState.cameras.first(where: { $0.name == review.camera })?.aspectRatio ?? 16.0 / 9.0
    }

    /// The lifecycle beat the user tapped in the timeline (nil = none).
    private var selectedBeat: TimelineBeat? {
        guard let ts = highlightTS else { return nil }
        return trackingBeats.first(where: { abs($0.ts - ts) < 0.001 })
    }
    private var trackingCameraHeight: Int {
        appState.cameras.first(where: { $0.name == review.camera })?.height ?? 720
    }
    /// The frame the Tracking tab shows: the RECORDED frame at the tapped beat, else the primary
    /// detection's clean best frame.
    private var trackingFrameURL: URL? {
        guard let client = appState.client, let pid = FrigateClient.primaryDetectionID(of: review) else { return nil }
        if let beat = selectedBeat {
            return client.recordingFrameURL(camera: review.camera, at: beat.ts, height: trackingCameraHeight)
        }
        return client.eventCleanSnapshotURL(id: pid)
    }
    /// Frigate's recorded frames run ~this far AHEAD of the detection boxes, so the box is advanced
    /// this many seconds along the path to land on the object in the shown recorded frame. Tunable.
    private static let recordingLead: Double = 0.7

    /// The selected beat's box, ADVANCED along the path to where the object is in the recorded frame.
    private var trackingBox: CGRect? {
        guard let beat = selectedBeat, let box0 = beat.box else { return nil }
        let pts = primaryEvent?.pathData ?? []
        guard !pts.isEmpty else { return box0 }
        let pos = pathPosition(pts, at: beat.ts + Self.recordingLead)   // bottom-centre
        return CGRect(x: pos.x - box0.width / 2, y: pos.y - box0.height, width: box0.width, height: box0.height)
    }
    /// The tail's highlight ring rides the same advanced moment so it too sits on the object.
    private var trackingHighlightTS: Double? {
        selectedBeat.map { $0.ts + Self.recordingLead }
    }
    /// Normalized point the inline Tracking view zooms toward: the advanced box centre, else the
    /// object's position in the best frame, else the path centroid, else centre.
    private var trackingFocus: CGPoint {
        if let b = trackingBox { return CGPoint(x: b.midX, y: b.midY) }
        let pts = primaryEvent?.pathData ?? []
        if let ts = primaryEvent?.snapshotFrameTime, let p = pts.min(by: { abs($0.ts - ts) < abs($1.ts - ts) }) {
            return CGPoint(x: p.x, y: p.y)
        }
        if !pts.isEmpty {
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return CGPoint(x: ((xs.min() ?? 0.5) + (xs.max() ?? 0.5)) / 2, y: ((ys.min() ?? 0.5) + (ys.max() ?? 0.5)) / 2)
        }
        return CGPoint(x: 0.5, y: 0.5)
    }

    private var mediaPlaceholder: some View {
        Color.black.mediaAspectFrame(mediaAspect)
    }

    @ViewBuilder
    private var trackingCard: some View {
        if !trackingBeats.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                    SectionHeader("Tracking")
                    Text("Tap a step to jump to that moment")
                        .font(.caption).foregroundStyle(GlassTheme.secondary)
                    ObjectTimelineView(beats: trackingBeats, eventStart: review.startTime, highlightTS: $highlightTS)
                }
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        } else if loadingTracking {
            GlassCard { SkeletonBlock().frame(height: 90) }
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
