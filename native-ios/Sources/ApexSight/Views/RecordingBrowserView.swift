import AVFoundation
import AVKit
import SwiftUI

struct RecordingBrowserView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @State private var selectedDate = Date()
    @State private var recordings: [FrigateRecording] = []
    @State private var dayEvents: [FrigateEvent] = []
    @StateObject private var clipModel = ClipPlayerModel()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isDownloading = false
    @State private var downloadFeedback: String?
    /// True when `downloadFeedback` is an error, so the banner shows red instead of success-green.
    @State private var downloadFeedbackIsError = false
    @State private var isPreparingShare = false
    @State private var sharePayload: SharePayload?

    // Scrubber state
    @State private var scrubFraction: Double = 0      // 0…1 across the selected day
    @State private var isScrubbing = false
    @State private var playingTime: Double?           // epoch currently playing
    @State private var rangeStartHour: Int = 0
    @State private var rangeEndHour: Int = 23
    /// Index of the event tick the playhead most recently crossed — used to fire a single
    /// selection tick when the finger snaps past a detection, instead of buzzing continuously.
    @State private var lastTickedEventIndex: Int?
    /// Best-effort continuous preview frame timestamps for the visible range (Frigate Preview
    /// API). Empty when previews are unavailable; scrubbing degrades to event thumbnails.
    @State private var previewFrames: [FrigateClient.PreviewFrame] = []
    /// The in-flight scrub-preview fetch, held so a day-switch can cancel it — otherwise an older
    /// day's frames could resolve last and overwrite the current day's preview bubble.
    @State private var previewTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let calendar = Calendar.current
    private let windowSeconds: Double = 300           // 5-minute clip per scrub

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    sectionTitle
                    datePicker
                    if isLoading {
                        loadingCard
                    } else if let errorMessage {
                        errorCard(errorMessage)
                    } else {
                        scrubberCard
                        if let player = clipModel.player {
                            playerCard(player)
                        }
                        if recordings.isEmpty {
                            noRecordingsCard
                        } else {
                            recordingList
                        }
                    }
                }
                .padding(GlassTheme.Space.l)
                // Keep it a comfortable, centered column on iPad instead of stretching.
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task { await loadDay(selectedDate) }
        .onChange(of: selectedDate) { _, date in
            Task { await loadDay(date) }
        }
        .onDisappear { clipModel.stop(); previewTask?.cancel() }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
    }

    private func shareCurrent() async {
        guard let client = appState.client, let start = playingTime else { return }
        Haptics.tap()
        isPreparingShare = true
        downloadFeedback = nil
        defer { isPreparingShare = false }
        do {
            let url = try await ClipDownloader.downloadToTempFile(
                url: client.recordingClipURL(camera: camera.name, start: start, end: start + windowSeconds),
                client: client, fileName: "Apex-\(camera.name)-\(Int(start))"
            )
            sharePayload = SharePayload(url: url)
        } catch {
            downloadFeedbackIsError = true
            downloadFeedback = error.localizedDescription
        }
    }

    // MARK: - Header

    private var sectionTitle: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
            Text(titleize(camera.name))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(GlassTheme.primary)
            Text("Recording timeline")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    /// Skeleton while the day's recordings + events load, so the screen keeps its shape
    /// instead of a lone spinner.
    private var loadingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SkeletonBlock(cornerRadius: GlassTheme.Radius.chip)
                    .frame(height: 96)
                SkeletonBlock()
                    .frame(width: 160, height: 14)
            }
        }
    }

    /// Calm error state with a retry, so a failed day fetch is recoverable instead of a
    /// blank timeline.
    private func errorCard(_ message: String) -> some View {
        GlassCard {
            VStack(spacing: GlassTheme.Space.m) {
                EmptyStateView(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't load this day",
                    message: message
                )
                Button {
                    Haptics.tap()
                    Task { await loadDay(selectedDate) }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
            }
        }
    }

    private var datePicker: some View {
        GlassCard {
            HStack(spacing: GlassTheme.Space.m) {
                circleStepButton(systemName: "chevron.left", enabled: true) { shiftDate(by: -1) }
                Spacer(minLength: GlassTheme.Space.s)
                VStack(spacing: GlassTheme.Space.xs) {
                    Text(selectedDate, style: .date)
                        .font(.headline)
                        .foregroundStyle(GlassTheme.primary)
                    if calendar.isDateInToday(selectedDate) {
                        Text("Today")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, GlassTheme.Space.s)
                            .padding(.vertical, 3)
                            .background(GlassTheme.accent, in: Capsule())
                    }
                }
                Spacer(minLength: GlassTheme.Space.s)
                circleStepButton(
                    systemName: "chevron.right",
                    enabled: !calendar.isDateInToday(selectedDate)
                ) { shiftDate(by: 1) }
                .disabled(calendar.isDateInToday(selectedDate))
            }
        }
    }

    /// Native material circle button used for prev/next day stepping.
    private func circleStepButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(enabled ? GlassTheme.accent : GlassTheme.tertiary)
                .frame(width: 44, height: 44)
                .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
        }
        .buttonStyle(.plain)
    }

    private func shiftDate(by days: Int) {
        guard let newDate = calendar.date(byAdding: .day, value: days, to: selectedDate),
              newDate <= Date() else { return }
        selectedDate = newDate
    }

    // MARK: - Scrubber

    private var scrubberCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Timeline") {
                    Text(scrubTimeLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                        .monospacedDigit()
                }

                scrubberTrack
                    .frame(height: 96)

                // Hour labels for current range. The range end is exclusive (rangeEndHour+1),
                // so the right label reflects the actual boundary covered.
                HStack {
                    Text(hourLabel(rangeStartHour))
                    Spacer()
                    Text(hourLabel((rangeStartHour + rangeEndHour) / 2))
                    Spacer()
                    Text(hourLabel((rangeEndHour + 1) % 24))
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(GlassTheme.tertiary)
                .monospacedDigit()

                // Quick range chips — friendlier than hour menus, snap the timeline to a
                // part of the day in one tap.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: GlassTheme.Space.s) {
                        rangeChip("All day", 0, 23)
                        rangeChip("Morning", 5, 11)
                        rangeChip("Afternoon", 11, 17)
                        rangeChip("Evening", 17, 23)
                        rangeChip("Night", 0, 5)
                    }
                    .padding(.horizontal, 1)
                }

                legend
            }
        }
    }

    private var scrubberTrack: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let px = (CGFloat(scrubFraction) * w).clampedX(in: w)
            ZStack(alignment: .topLeading) {
                // Track background — deeper, rounded, with a hairline so it reads as a real groove.
                RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                    .fill(GlassTheme.surfaceHigh)
                    .overlay {
                        RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                            .strokeBorder(GlassTheme.separator, lineWidth: 1)
                    }

                // Recording coverage + colored event ticks
                Canvas { ctx, size in
                    let dayStart = calendar.startOfDay(for: selectedDate).timeIntervalSince1970

                    // coverage strip along the bottom
                    let rangeStartSec = dayStart + Double(rangeStartHour) * 3600
                    let rangeEndSec = dayStart + Double(rangeEndHour + 1) * 3600
                    let rangeDuration = max(1, rangeEndSec - rangeStartSec)
                    for rec in recordings {
                        guard let s = rec.startTime else { continue }
                        let f = (s - rangeStartSec) / rangeDuration
                        guard f >= 0, f <= 1 else { continue }
                        let x = f * size.width
                        let cov = CGRect(x: x, y: size.height - 7, width: max(1, size.width / 24 / 12), height: 6)
                        ctx.fill(
                            Path(roundedRect: cov, cornerRadius: 1),
                            with: .color(.white.opacity(0.16))
                        )
                    }

                    // event ticks, colored by object
                    for e in dayEvents {
                        guard let s = e.startTime else { continue }
                        let f = (s - rangeStartSec) / rangeDuration
                        guard f >= 0, f <= 1 else { continue }
                        let x = f * size.width
                        let rect = CGRect(x: x - 1.25, y: 10, width: 2.5, height: size.height - 24)
                        ctx.fill(
                            Path(roundedRect: rect, cornerRadius: 1.25),
                            with: .color(color(for: e.label))
                        )
                    }
                }
                .padding(.horizontal, 2)

                // Playhead — thin accent line with a large, clearly draggable handle.
                Rectangle()
                    .fill(GlassTheme.accent)
                    .frame(width: 2, height: h)
                    .offset(x: px)
                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .overlay { Circle().strokeBorder(GlassTheme.accent, lineWidth: 4) }
                    .scaleEffect(isScrubbing ? 1.18 : 1)
                    .offset(x: px - 11, y: h / 2 - 11)
                    .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: isScrubbing)

                // Floating scrub-preview bubble above the playhead while dragging.
                if isScrubbing {
                    scrubPreviewBubble(width: w, playheadX: px)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: isScrubbing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            Haptics.select()
                            lastTickedEventIndex = nil
                        }
                        isScrubbing = true
                        let f = Double(max(0, min(value.location.x / w, 1)))
                        updateSnapHaptic(for: f)
                        scrubFraction = f
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        lastTickedEventIndex = nil
                        playFromScrub()
                    }
            )
            // Smoothly settle the playhead when the position is set programmatically
            // (e.g. parked on the latest detection), but follow the finger 1:1 while dragging.
            .animation(isScrubbing ? nil : .easeOut(duration: 0.2), value: scrubFraction)
            // VoiceOver: expose the gesture-only scrubber as one adjustable control so it can
            // be moved with the rotor's increment/decrement instead of a drag it can't perform.
            .accessibilityElement()
            .accessibilityLabel("Recording timeline")
            .accessibilityValue(scrubAccessibilityValue)
            .accessibilityHint("Swipe up or down to scrub through the day")
            .accessibilityAdjustableAction { direction in
                let step = 0.02
                switch direction {
                case .increment: scrubFraction = min(1, scrubFraction + step)
                case .decrement: scrubFraction = max(0, scrubFraction - step)
                @unknown default: break
                }
                playFromScrub()
            }
        }
    }

    /// Time-of-day the playhead currently sits on, spoken by VoiceOver for the scrubber.
    private var scrubAccessibilityValue: String {
        let dayStart = calendar.startOfDay(for: selectedDate).timeIntervalSince1970
        let rangeStartSec = dayStart + Double(rangeStartHour) * 3600
        let rangeEndSec = dayStart + Double(rangeEndHour + 1) * 3600
        let t = rangeStartSec + scrubFraction * (rangeEndSec - rangeStartSec)
        return Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened)
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                legendDot("Person", .red)
                legendDot("Vehicle", .green)
                legendDot("Animal", .yellow)
                legendDot("Bike", .orange)
                legendDot("Package", .cyan)
                legendDot("Other", .purple)
            }
        }
    }

    private func rangeChip(_ title: String, _ start: Int, _ end: Int) -> some View {
        let selected = rangeStartHour == start && rangeEndHour == end
        return Button {
            Haptics.select()
            rangeStartHour = start
            rangeEndHour = end
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? .white : GlassTheme.secondary)
                .padding(.horizontal, GlassTheme.Space.m)
                .padding(.vertical, GlassTheme.Space.s)
                .background {
                    if selected {
                        Capsule().fill(GlassTheme.accent)
                    } else {
                        Capsule().fill(GlassTheme.surface)
                        Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1)
                    }
                }
                // Compact pill, 44pt hit target (HIG minimum).
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func legendDot(_ title: String, _ color: Color) -> some View {
        HStack(spacing: GlassTheme.Space.xs) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    /// Start/end epoch of the currently selected hour range.
    private var rangeBounds: (start: Double, end: Double) {
        let dayStart = calendar.startOfDay(for: selectedDate).timeIntervalSince1970
        return (dayStart + Double(rangeStartHour) * 3600,
                dayStart + Double(rangeEndHour + 1) * 3600)
    }

    /// Epoch time under the playhead for the current scrub fraction.
    private var scrubEpoch: Double {
        let b = rangeBounds
        return b.start + scrubFraction * (b.end - b.start)
    }

    private var scrubTimeLabel: String {
        Date(timeIntervalSince1970: scrubEpoch).formatted(date: .omitted, time: .shortened)
    }

    /// The detection nearest the playhead, but only when it's within ~3 minutes — close
    /// enough that its still is representative of what the user is scrubbing toward.
    private var nearestEvent: FrigateEvent? {
        let t = scrubEpoch
        let candidate = dayEvents
            .compactMap { e -> (FrigateEvent, Double)? in
                guard let s = e.startTime else { return nil }
                return (e, abs(s - t))
            }
            .min { $0.1 < $1.1 }
        guard let (event, delta) = candidate, delta <= 180 else { return nil }
        return event
    }

    /// Best continuous preview frame for the playhead time, when the Preview API is
    /// available — used to keep the bubble live even between detections.
    private var nearestPreviewURL: URL? {
        guard !previewFrames.isEmpty, let client = appState.client else { return nil }
        let t = scrubEpoch
        guard let frame = previewFrames.min(by: { abs($0.time - t) < abs($1.time - t) }) else { return nil }
        return client.previewFrameURL(filename: frame.filename)
    }

    /// Floating preview shown above the playhead while dragging — Protect's "zoomed-in
    /// still while scrubbing", driven entirely by data we already hold (nearest detection
    /// thumbnail), with a continuous preview frame as a bonus when Frigate exposes it, and a
    /// graceful degrade to just the time label when neither is near.
    @ViewBuilder
    private func scrubPreviewBubble(width: CGFloat, playheadX: CGFloat) -> some View {
        let event = nearestEvent
        let thumbURL = event.flatMap { appState.client?.eventThumbnailURL(id: $0.id) } ?? nearestPreviewURL
        VStack(spacing: GlassTheme.Space.xs) {
            ZStack {
                if let thumbURL {
                    RemoteImage(url: thumbURL, contentMode: .fill)
                } else {
                    GlassTheme.surfaceHigh
                    Image(systemName: "clock")
                        .font(.title3)
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
            .frame(width: 112, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))

            VStack(spacing: 1) {
                Text(scrubTimeLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GlassTheme.primary)
                    .monospacedDigit()
                if let event {
                    Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(GlassTheme.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(GlassTheme.Space.s)
        .frame(width: bubbleWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous)
                .strokeBorder(GlassTheme.separator, lineWidth: 1)
        }
        // Keep the bubble on-screen: it tracks the playhead but clamps near the edges.
        .offset(x: max(0, min(playheadX - bubbleWidth / 2, width - bubbleWidth)), y: -100)
        .allowsHitTesting(false)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityHidden(true)
    }

    /// Fixed width of the scrub-preview bubble — used both to size it and to clamp it
    /// inside the track so it never runs off either edge.
    private var bubbleWidth: CGFloat { 128 }

    /// Fire one selection tick when the dragging playhead crosses a detection tick, so
    /// scrubbing has the same tactile "click past markers" feel as a native picker.
    private func updateSnapHaptic(for fraction: Double) {
        let b = rangeBounds
        let span = max(1, b.end - b.start)
        let t = b.start + fraction * span
        // ~6px worth of time on a typical track counts as "on" a tick.
        let tolerance = span * 0.012
        var hitIndex: Int?
        for (i, e) in dayEvents.enumerated() {
            guard let s = e.startTime else { continue }
            if abs(s - t) <= tolerance { hitIndex = i; break }
        }
        if let hitIndex, hitIndex != lastTickedEventIndex {
            Haptics.select()
        }
        lastTickedEventIndex = hitIndex
    }

    private func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h)\(hour < 12 ? "a" : "p")"
    }

    private func color(for label: String) -> Color {
        switch label.lowercased() {
        case "person": return .red
        case "car", "truck", "bus", "vehicle", "motorcycle_vehicle": return .green
        case "dog", "cat", "bird", "deer", "fox", "raccoon", "horse", "bear", "rabbit", "squirrel", "animal":
            return .yellow
        case "bicycle", "motorcycle": return .orange
        case "package": return .cyan
        default: return .purple
        }
    }

    // MARK: - Player

    private func playerCard(_ player: AVPlayer) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader(
                    playingTime.map {
                        "Playing from \(Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened))"
                    } ?? "Playing Clip"
                )

                ZStack {
                    PiPPlayerView(player: player)
                        .opacity(clipModel.isReady ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeIn(duration: 0.25), value: clipModel.isReady)
                    // Each scrub loads a fresh VOD window; hold a skeleton over it until the
                    // new moment is ready instead of flashing black.
                    if !clipModel.isReady { ClipSkeleton() }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                .cardStroke(GlassTheme.Radius.tile)
                .expandableMedia(.player(player))

                HStack(spacing: GlassTheme.Space.s) {
                    Button {
                        Task { await shareCurrent() }
                    } label: {
                        HStack(spacing: GlassTheme.Space.s) {
                            if isPreparingShare {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text(isPreparingShare ? "Preparing…" : "Share")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                    .disabled(isPreparingShare || playingTime == nil)

                    Button {
                        Task { await downloadCurrent() }
                    } label: {
                        HStack(spacing: GlassTheme.Space.s) {
                            if isDownloading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text(isDownloading ? "Saving…" : "Save")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                    .disabled(isDownloading || playingTime == nil)
                }
                .opacity(playingTime == nil ? 0.5 : 1)

                if let downloadFeedback {
                    Text(downloadFeedback)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(downloadFeedbackIsError ? GlassTheme.red : GlassTheme.green)
                }
            }
        }
    }

    private var noRecordingsCard: some View {
        GlassCard {
            EmptyStateView(
                icon: "calendar.badge.exclamationmark",
                title: "No recordings",
                message: "No recordings found for this date."
            )
        }
    }

    // MARK: - Event jump list (recent detections that day)

    private var recordingList: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader(dayEvents.isEmpty ? "Recordings" : "Detections") {
                    Text(dayEvents.isEmpty ? "\(recordings.count) segments" : "\(dayEvents.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.secondary)
                        .monospacedDigit()
                }

                if dayEvents.isEmpty {
                    Text("Scrub the timeline above to play any moment.")
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                } else {
                    VStack(spacing: GlassTheme.Space.s) {
                        ForEach(dayEvents.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }) { event in
                            eventJumpRow(event)
                        }
                    }
                }
            }
        }
    }

    private func eventJumpRow(_ event: FrigateEvent) -> some View {
        Button {
            if let start = event.startTime { playFrom(time: start) }
        } label: {
            HStack(spacing: GlassTheme.Space.m) {
                ZStack(alignment: .topLeading) {
                    if let url = appState.client?.eventThumbnailURL(id: event.id) {
                        RemoteImage(url: url, contentMode: .fill)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                            .fill(GlassTheme.surfaceHigh)
                            .frame(width: 52, height: 52)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.subheadline)
                                    .foregroundStyle(GlassTheme.tertiary)
                            }
                    }
                    // Small semantic dot keyed to the detection's object color.
                    Circle()
                        .fill(color(for: event.label))
                        .frame(width: 9, height: 9)
                        .overlay { Circle().strokeBorder(GlassTheme.surface, lineWidth: 1.5) }
                        .offset(x: -3, y: -3)
                }
                VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                    Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.primary)
                        .lineLimit(1)
                    if let start = event.startTime {
                        Text(Date(timeIntervalSince1970: start), style: .time)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
                Spacer(minLength: GlassTheme.Space.s)
                Image(systemName: "play.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GlassTheme.accent)
            }
            .padding(GlassTheme.Space.s)
            .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            .cardStroke(GlassTheme.Radius.tile)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data + playback

    private func loadDay(_ date: Date) async {
        guard let client = appState.client else { return }
        isLoading = true
        errorMessage = nil
        clipModel.stop()
        playingTime = nil
        downloadFeedback = nil

        previewFrames = []
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        async let recs = client.recordings(camera: camera.name, after: startOfDay, end: endOfDay)
        async let evs = client.events(
            camera: camera.name, after: startOfDay, before: endOfDay, limit: 500
        )

        // Recordings are the page's spine — if that fetch fails, surface a retry instead
        // of a silently-empty timeline. Events are best-effort and never fail the screen.
        do {
            recordings = try await recs.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        } catch {
            recordings = []
            dayEvents = []
            errorMessage = error.localizedDescription
            isLoading = false
            return
        }
        dayEvents = (try? await evs) ?? []

        // Park the playhead on the most recent detection and start playing immediately.
        if let latest = dayEvents.compactMap(\.startTime).max() {
            let rangeStart = startOfDay.timeIntervalSince1970 + Double(rangeStartHour) * 3600
            let rangeEnd = startOfDay.timeIntervalSince1970 + Double(rangeEndHour + 1) * 3600
            let rangeSeconds = max(1, rangeEnd - rangeStart)
            scrubFraction = max(0, min((latest - rangeStart) / rangeSeconds, 1))
        }
        isLoading = false
        // Auto-play from the parked position so the user sees footage immediately.
        if !recordings.isEmpty { playFromScrub() }

        // Best-effort continuous scrub previews. Fully detached and defensive: it no-ops on
        // any failure and only enriches the bubble — it never blocks load or scrubbing. Cancelled
        // and guarded on the day so a slow fetch for a previous day can't clobber the current one.
        previewTask?.cancel()
        previewTask = Task {
            let frames = await client.previewFrames(
                camera: camera.name,
                start: startOfDay.timeIntervalSince1970,
                end: endOfDay.timeIntervalSince1970
            )
            guard !Task.isCancelled, date == selectedDate, !frames.isEmpty else { return }
            previewFrames = frames
        }
    }

    private func playFromScrub() {
        let dayStart = calendar.startOfDay(for: selectedDate).timeIntervalSince1970
        let rangeStart = dayStart + Double(rangeStartHour) * 3600
        let rangeEnd = dayStart + Double(rangeEndHour + 1) * 3600
        let rangeSeconds = rangeEnd - rangeStart
        let time = rangeStart + scrubFraction * rangeSeconds
        let cappedNow = Date().timeIntervalSince1970 - windowSeconds
        playFrom(time: min(time, cappedNow))
    }

    private func playFrom(time: Double) {
        guard let client = appState.client else { return }
        let dayStart = calendar.startOfDay(for: selectedDate).timeIntervalSince1970
        let rangeStart = dayStart + Double(rangeStartHour) * 3600
        let rangeEnd = dayStart + Double(rangeEndHour + 1) * 3600
        let rangeSeconds = max(1, rangeEnd - rangeStart)
        scrubFraction = max(0, min((time - rangeStart) / rangeSeconds, 1))

        downloadFeedback = nil
        playingTime = time
        // VOD HLS for this 5-min window — Frigate's documented recording playback source.
        clipModel.load(
            client: client,
            url: client.recordingHLSURL(camera: camera.name, start: time, end: time + windowSeconds)
        )
    }

    private func downloadCurrent() async {
        guard let client = appState.client, let start = playingTime else { return }
        isDownloading = true
        downloadFeedback = nil
        defer { isDownloading = false }
        do {
            let url = client.recordingClipURL(camera: camera.name, start: start, end: start + windowSeconds)
            try await ClipDownloader.downloadToPhotos(url: url, client: client, fileName: "Apex-\(camera.name)-\(Int(start))")
            downloadFeedbackIsError = false
            downloadFeedback = "Saved to Photos."
        } catch {
            downloadFeedbackIsError = true
            downloadFeedback = error.localizedDescription
        }
    }
}

private extension CGFloat {
    /// Keeps the playhead handle inside the track bounds.
    func clampedX(in width: CGFloat) -> CGFloat {
        Swift.max(0, Swift.min(self, width))
    }
}
