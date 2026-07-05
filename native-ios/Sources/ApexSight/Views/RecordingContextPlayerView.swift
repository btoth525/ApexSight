import SwiftUI
import AVFoundation

/// The event "History" view: plays the recording around an event on a real **activity timeline** —
/// every detection in the window shown as a tappable marker (color-coded by object), a live
/// playhead, a crisp scrub-preview thumbnail while dragging, and a full-screen expand button.
struct RecordingContextPlayerView: View {
    let camera: String
    let centerTime: Double
    let eventStart: Double?
    let eventEnd: Double?
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = ClipPlayerModel()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isSliding = false
    @State private var isPlaying = true
    @State private var previewFrames: [FrigateClient.PreviewFrame] = []
    @State private var windowEvents: [FrigateEvent] = []
    @State private var showExpanded = false
    @State private var scrubPreviewURL: URL?

    private let windowSeconds: Double = 300  // ±5 minutes
    private let seekTolerance = CMTime(seconds: 1, preferredTimescale: 600)

    private var windowStart: Double { centerTime - windowSeconds / 2 }
    private var windowEnd: Double { centerTime + windowSeconds / 2 }
    /// Epoch of the current playhead (window-relative time → absolute).
    private var playheadEpoch: Double { windowStart + currentTime }

    var body: some View {
        VStack(spacing: GlassTheme.Space.m) {
            player
            timeline
            controls
        }
        .task {
            guard let client = appState.client else { return }
            model.loadIfNeeded(client: client, url: client.recordingHLSURL(camera: camera, start: windowStart, end: windowEnd))
            if let es = eventStart {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let player = model.player {
                    _ = await player.seek(to: CMTime(seconds: max(0, es - windowStart - 5), preferredTimescale: 600),
                                          toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
                }
            }
        }
        .task {
            previewFrames = await appState.client?.previewFrames(camera: camera, start: windowStart, end: windowEnd) ?? []
        }
        .task {
            // Every detection in this window → timeline markers.
            windowEvents = (try? await appState.client?.events(
                camera: camera,
                after: Date(timeIntervalSince1970: windowStart),
                before: Date(timeIntervalSince1970: windowEnd),
                limit: 50
            )) ?? []
        }
        .onDisappear { if !showExpanded { model.stop() } }
        .fullScreenCover(isPresented: $showExpanded, onDismiss: { model.play() }) {
            if let player = model.player { FullscreenMediaView(media: .player(player)) }
        }
    }

    // MARK: - Video

    private var player: some View {
        LoadingClipPlayer(model: model)
            .frame(height: 240)
            .frame(maxWidth: .infinity)
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

    // MARK: - Activity timeline

    private func fraction(for epoch: Double) -> CGFloat {
        CGFloat(min(max((epoch - windowStart) / windowSeconds, 0), 1))
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

                    // Detection markers — one per event, colored by object.
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

                    // Playhead.
                    Circle().fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .offset(x: width * playheadFraction - 8)

                    // Scrub-preview thumbnail bubble.
                    if isSliding, let url = scrubPreviewURL {
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
                            updateScrubPreview()
                        }
                        .onEnded { v in
                            let frac = min(max(v.location.x / width, 0), 1)
                            seek(to: Double(frac) * max(duration, 1))
                            isSliding = false
                        }
                )
            }
            .frame(height: 44)

            // Time axis.
            HStack {
                Text(formatTime(windowStart)).font(.caption2.monospacedDigit()).foregroundStyle(GlassTheme.tertiary)
                Spacer()
                Text(formatTime(centerTime)).font(.caption2.monospacedDigit()).foregroundStyle(GlassTheme.tertiary)
                Spacer()
                Text(formatTime(windowEnd)).font(.caption2.monospacedDigit()).foregroundStyle(GlassTheme.tertiary)
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
                Text("\(windowEvents.count) event\(windowEvents.count == 1 ? "" : "s") in ±5 min")
                    .font(.caption2).foregroundStyle(GlassTheme.tertiary)
            }

            Spacer(minLength: GlassTheme.Space.s)

            if let es = eventStart {
                Button { seek(toEpoch: es + 0.5); model.play() } label: {
                    Label("This Event", systemImage: "scope")
                        .font(.footnote.weight(.semibold)).labelStyle(.titleAndIcon)
                        .foregroundStyle(GlassTheme.accent)
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
    }

    // MARK: - Helpers

    private func seek(to windowRelative: Double) {
        currentTime = windowRelative
        model.player?.seek(to: CMTime(seconds: windowRelative, preferredTimescale: 600),
                           toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
    }
    private func seek(toEpoch epoch: Double) {
        Haptics.select()
        seek(to: max(0, epoch - windowStart))
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
