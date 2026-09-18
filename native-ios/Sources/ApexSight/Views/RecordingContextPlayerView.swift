import SwiftUI
import AVFoundation

/// The event "History" player, built around the tracked object rather than the wall clock.
///
/// Two modes, one AVPlayer:
///
/// - **Event** (default): a tight VOD bounded to the object's OWN window — `recordingHLSURL(start,
///   end)`, which Frigate clips to the requested range (measured 2026-09-17: a 22 s request returns
///   23.9 s of media starting at the requested second, not whole ~10 s segments). It loops. The
///   scrubber underneath spans exactly that window, so every pixel of the track means something and
///   the object is on screen from the first frame. This replaces the old behaviour where History
///   opened a 5-minute window and seeked to `start − 5 s`, which dropped you ~10 s before the object
///   and was slow to load a clip 15× longer than the moment you cared about.
/// - **Full recording**: the ±5-minute context — every detection in the window as a tappable
///   marker, a crisp scrub-preview thumbnail while dragging, and a jump back to the tracked event.
///   For searching back before the moment and forward after it. One tap from Event mode.
struct RecordingContextPlayerView: View {
    let camera: String
    /// Centre of the FULL-recording context window (the review / event start).
    let centerTime: Double
    /// The tracked object's own window — the Event-mode clip is bounded to this. For a Review this
    /// is the primary detection's span (not the bundled review window); for an Event it's the event.
    let eventStart: Double?
    let eventEnd: Double?
    /// When set, the player fills the camera's true frame aspect (no letterbox) so it matches
    /// the Snapshot / Tracking tabs. nil keeps the standalone fixed 240pt height.
    var frameAspect: CGFloat? = nil

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = ClipPlayerModel()

    enum Mode: String { case event, full }
    @State private var mode: Mode = .event
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isSliding = false
    @State private var isPlaying = true
    @State private var previewFrames: [FrigateClient.PreviewFrame] = []
    @State private var windowEvents: [FrigateEvent] = []
    @State private var showExpanded = false
    @State private var scrubPreviewURL: URL?

    // Full-recording context span.
    private let windowSeconds: Double = 300  // ±5 minutes
    private let seekTolerance = CMTime(seconds: 1, preferredTimescale: 600)
    // Event-clip bounds. The floor extends the clip AFTER the event (a very short track still needs
    // a real span — Frigate 404s a zero-length range, measured 2026-09-12) — never a lead-in, which
    // is the dead pre-roll this rebuild exists to remove. The cap stops a re-linked, hours-long
    // parked track (measured worst case 3 h 09 m) from opening an enormous clip.
    private let minEventSeconds: Double = 8
    private let maxEventSeconds: Double = 120

    private var windowStart: Double { centerTime - windowSeconds / 2 }
    private var windowEnd: Double { centerTime + windowSeconds / 2 }
    /// Clamped for the actual VOD request only — Frigate may not have flushed segments this recent
    /// to its recordings DB yet. The displayed timeline keeps the true span so labels don't jump.
    private var requestWindowEnd: Double { min(windowEnd, Date().timeIntervalSince1970) }

    /// The tracked object's clip window, clamped to a sane, playable span.
    private var eventClipStart: Double { eventStart ?? centerTime }
    private var eventClipEnd: Double {
        let start = eventClipStart
        let rawEnd = eventEnd ?? Date().timeIntervalSince1970
        let floored = max(rawEnd, start + minEventSeconds)
        return min(min(floored, start + maxEventSeconds), Date().timeIntervalSince1970)
    }

    /// The span the timeline represents in the current mode.
    private var spanStart: Double { mode == .event ? eventClipStart : windowStart }
    private var displaySeconds: Double { max(duration, 1) }
    /// Epoch of the current playhead (span-relative → absolute).
    private var playheadEpoch: Double { spanStart + currentTime }

    private func clipURL(for mode: Mode) -> URL? {
        guard let client = appState.client else { return nil }
        switch mode {
        case .event: return client.recordingHLSURL(camera: camera, start: eventClipStart, end: eventClipEnd)
        case .full:  return client.recordingHLSURL(camera: camera, start: windowStart, end: requestWindowEnd)
        }
    }

    var body: some View {
        VStack(spacing: GlassTheme.Space.m) {
            player
            timeline
            controls
        }
        // Keyed so a REUSED view — or a mode switch, or the primary detection resolving after load
        // (which moves eventStart) — reloads for the right window. `loadIfNeeded` no-ops on an
        // unchanged URL, so flipping back to a mode you already loaded is instant.
        .task(id: "\(camera)|\(Int(centerTime))|\(mode.rawValue)|\(Int(eventClipStart))|\(Int(eventClipEnd))") {
            guard let client = appState.client, let url = clipURL(for: mode) else { return }
            model.loopsAtEnd = (mode == .event)   // the tracked event loops; the context plays through
            currentTime = 0
            model.loadIfNeeded(client: client, url: url)
            guard mode == .full, let es = eventStart else { return }
            // Full mode opens on the event, not 5 s early. Seek once the item can actually seek — a
            // fixed wait was a guess the playlists had parsed; over the tunnel they often hadn't and
            // an HLS item seeked too early clamps to offset 0.
            while !model.isReady {
                if model.hasError || Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let player = model.player {
                _ = await player.seek(to: CMTime(seconds: max(0, es - windowStart), preferredTimescale: 600),
                                      toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
            }
        }
        // Context data (markers + scrub thumbnails) is only meaningful — and only worth the network
        // — in Full mode, so it loads lazily the first time you switch there. Event mode stays fast.
        .task(id: mode) {
            guard mode == .full else { return }
            if previewFrames.isEmpty {
                previewFrames = await appState.client?.previewFrames(camera: camera, start: windowStart, end: windowEnd) ?? []
            }
            if windowEvents.isEmpty {
                windowEvents = (try? await appState.client?.events(
                    camera: camera,
                    after: Date(timeIntervalSince1970: windowStart),
                    before: Date(timeIntervalSince1970: windowEnd),
                    limit: 50
                )) ?? []
            }
        }
        .onDisappear { if !showExpanded { model.stop() } }
        .fullScreenCover(isPresented: $showExpanded, onDismiss: { model.play() }) {
            if let player = model.player { FullscreenMediaView(media: .player(player)) }
        }
    }

    // MARK: - Video

    private var player: some View {
        clipFrame(LoadingClipPlayer(model: model))
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
            .cardStroke(GlassTheme.Radius.card)
            .overlay(alignment: .topTrailing) {
                Button { Haptics.tap(); showExpanded = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .black))
                        .frame(width: 36, height: 36)
                        .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                        .foregroundStyle(.white)
                }
                .padding(10)
                .accessibilityLabel("Expand to full screen")
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if Task.isCancelled { break }
                    guard let player = model.player else { continue }
                    isPlaying = player.timeControlStatus == .playing
                    guard !isSliding else { continue }
                    if let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 { duration = dur }
                    let t = player.currentTime().seconds
                    if t.isFinite { currentTime = min(max(t, 0), max(duration, 1)) }
                }
            }
    }

    @ViewBuilder
    private func clipFrame(_ content: some View) -> some View {
        if let frameAspect {
            content.mediaAspectFrame(frameAspect)
        } else {
            content.frame(height: 240).frame(maxWidth: .infinity)
        }
    }

    // MARK: - Timeline

    private func fraction(for epoch: Double) -> CGFloat {
        CGFloat(min(max((epoch - spanStart) / displaySeconds, 0), 1))
    }
    private var playheadFraction: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(currentTime / duration, 0), 1))
    }

    private var timeline: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    // Track.
                    Capsule().fill(GlassTheme.surfaceHigh).frame(height: 8)
                        .frame(maxHeight: .infinity, alignment: .center)
                    // Played portion.
                    Capsule().fill(GlassTheme.accent.opacity(0.55))
                        .frame(width: width * playheadFraction, height: 8)
                        .frame(maxHeight: .infinity, alignment: .center)

                    // Detection markers — Full mode only (one per event, colored by object).
                    if mode == .full {
                        ForEach(windowEvents) { ev in
                            if let s = ev.startTime {
                                let isThis = eventStart.map { abs($0 - s) < 1 } ?? false
                                Capsule()
                                    .fill(markerColor(ev.label))
                                    .frame(width: isThis ? 5 : 3, height: isThis ? 26 : 18)
                                    .overlay(isThis ? Capsule().stroke(.white, lineWidth: 1.5) : nil)
                                    .shadow(color: .black.opacity(0.4), radius: 1.5)
                                    .offset(x: width * fraction(for: s) - (isThis ? 2.5 : 1.5))
                                    .onTapGesture { seek(toEpoch: s + 0.5) }
                            }
                        }
                    }

                    // Playhead.
                    Circle().fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .offset(x: width * playheadFraction - 8)

                    // Scrub-preview thumbnail bubble — Full mode only.
                    if mode == .full, isSliding, let url = scrubPreviewURL {
                        VStack(spacing: 3) {
                            RemoteImage(url: url, contentMode: .fill, maxPixelSize: 260)
                                .frame(width: 128, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.5), lineWidth: 1))
                                .shadow(radius: 6)
                            Text(formatTime(playheadEpoch))
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                        }
                        .offset(x: min(max(width * playheadFraction - 64, 0), width - 128), y: -70)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            isSliding = true
                            let frac = min(max(v.location.x / width, 0), 1)
                            currentTime = Double(frac) * max(duration, 1)
                            if mode == .full { updateScrubPreview() }
                        }
                        .onEnded { v in
                            let frac = min(max(v.location.x / width, 0), 1)
                            seek(to: Double(frac) * max(duration, 1))
                            isSliding = false
                        }
                )
            }
            .frame(height: 44)
            .accessibilityElement()
            .accessibilityLabel(mode == .event ? "Event playback timeline" : "Recording timeline")
            .accessibilityValue("\(Int((playheadFraction * 100).rounded())) percent")
            .accessibilityHint("Swipe up or down to scrub")
            .accessibilityAdjustableAction { direction in
                let step = max(duration, 1) * 0.02
                switch direction {
                case .increment: seek(to: min(duration, currentTime + step))
                case .decrement: seek(to: max(0, currentTime - step))
                @unknown default: break
                }
            }

            // Time axis — spans the current mode's window, so it always matches the scrubber.
            HStack {
                Text(formatTime(spanStart)).font(.caption2.monospacedDigit()).foregroundStyle(GlassTheme.tertiary)
                Spacer()
                Text(formatTime(spanStart + displaySeconds / 2)).font(.caption2.monospacedDigit()).foregroundStyle(GlassTheme.tertiary)
                Spacer()
                Text(formatTime(spanStart + displaySeconds)).font(.caption2.monospacedDigit()).foregroundStyle(GlassTheme.tertiary)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: GlassTheme.Space.m) {
            Button {
                Haptics.tap()
                isPlaying ? model.pause() : model.play()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .black))
                    .frame(width: 44, height: 44)
                    .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                    .foregroundStyle(GlassTheme.primary)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            VStack(alignment: .leading, spacing: 1) {
                Text(formatTime(playheadEpoch))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(GlassTheme.primary)
                Text(subtitle)
                    .font(.caption2).foregroundStyle(GlassTheme.tertiary)
            }

            Spacer(minLength: GlassTheme.Space.s)

            modeButton
        }
    }

    /// The single mode switch: Event mode offers "Full recording"; Full mode offers a jump back to
    /// the tracked event. One button, so the primary action is always obvious and uncluttered.
    private var modeButton: some View {
        Button {
            Haptics.select()
            if mode == .event {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { mode = .full }
            } else {
                if let es = eventStart { seek(toEpoch: es) }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { mode = .event }
            }
        } label: {
            Label(mode == .event ? "Full recording" : "Tracked event",
                  systemImage: mode == .event ? "timeline.selection" : "scope")
                .font(.footnote.weight(.semibold)).labelStyle(.titleAndIcon)
                .foregroundStyle(GlassTheme.accent)
        }
        .buttonStyle(GlassButtonStyle())
        .accessibilityHint(mode == .event
            ? "Switches to the full recording so you can scrub before and after the event"
            : "Returns to the tracked event clip")
    }

    private var subtitle: String {
        if mode == .event {
            let secs = max(1, Int(eventClipEnd - eventClipStart))
            return "Tracked event · \(secs)s"
        }
        return "\(windowEvents.count) event\(windowEvents.count == 1 ? "" : "s") in ±5 min"
    }

    // MARK: - Helpers

    private func seek(to spanRelative: Double) {
        currentTime = spanRelative
        model.player?.seek(to: CMTime(seconds: spanRelative, preferredTimescale: 600),
                           toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
    }
    private func seek(toEpoch epoch: Double) {
        Haptics.select()
        seek(to: max(0, epoch - spanStart))
        model.play()
    }

    private func updateScrubPreview() {
        guard !previewFrames.isEmpty else { scrubPreviewURL = nil; return }
        let target = playheadEpoch
        if let nearest = previewFrames.min(by: { abs($0.time - target) < abs($1.time - target) }) {
            scrubPreviewURL = appState.client?.previewFrameURL(filename: nearest.filename)
        }
    }

    private func markerColor(_ label: String) -> Color {
        switch label.lowercased() {
        case "person": return GlassTheme.orange
        case "car", "truck", "bus", "motorcycle": return GlassTheme.accent
        case "dog", "cat", "bird", "horse": return GlassTheme.green
        default: return GlassTheme.purple
        }
    }

    private func formatTime(_ epoch: Double) -> String {
        Date(timeIntervalSince1970: epoch).formatted(date: .omitted, time: .shortened)
    }
}
