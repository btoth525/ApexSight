import SwiftUI
import AVFoundation

/// The event "History" view: plays the recording around an event with a **filmstrip timeline**
/// (thumbnails of the actual footage, a live playhead, and the event marker) and a full-screen
/// expand button — instead of a bare slider.
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
    @State private var showExpanded = false

    private let windowSeconds: Double = 300  // ±5 minutes
    /// Allow ~1s of slop on seeks — exact-frame seeks over HLS make scrubbing feel sluggish.
    private let seekTolerance = CMTime(seconds: 1, preferredTimescale: 600)

    private var windowStart: Double { centerTime - windowSeconds / 2 }
    private var windowEnd: Double { centerTime + windowSeconds / 2 }

    var body: some View {
        VStack(spacing: GlassTheme.Space.m) {
            player
            filmstrip
            controls
        }
        .task {
            guard let client = appState.client else { return }
            let url = client.recordingHLSURL(camera: camera, start: windowStart, end: windowEnd)
            model.loadIfNeeded(client: client, url: url)
            if let es = eventStart {
                let offset = es - windowStart
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let player = model.player {
                    _ = await player.seek(to: CMTime(seconds: max(0, offset - 5), preferredTimescale: 600),
                                          toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
                }
            }
        }
        .task {
            // Filmstrip thumbnails for the window (best-effort — degrades to a plain track).
            previewFrames = await appState.client?.previewFrames(camera: camera, start: windowStart, end: windowEnd) ?? []
        }
        // Presenting a fullScreenCover fires this onDisappear — do NOT stop the player then,
        // or the cover shows a dead player. Only stop when we actually leave the screen.
        .onDisappear { if !showExpanded { model.stop() } }
        .fullScreenCover(isPresented: $showExpanded, onDismiss: { model.play() }) {
            if let player = model.player {
                FullscreenMediaView(media: .player(player))
            }
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
                Button {
                    Haptics.tap()
                    showExpanded = true
                } label: {
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
                // Drive the scrub bar from the player clock (cancels on disappear).
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

    // MARK: - Filmstrip timeline

    private var playheadFraction: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(currentTime / duration, 0), 1))
    }

    /// Evenly sampled preview frames to fill the strip (kept small for memory/scroll).
    private var stripFrames: [FrigateClient.PreviewFrame] {
        HighlightReelBuilder.sampleEvenly(previewFrames, max: 14)
    }

    private var filmstrip: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // Thumbnails of the actual footage across the window.
                if stripFrames.isEmpty {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(GlassTheme.surfaceHigh)
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(stripFrames.enumerated()), id: \.offset) { _, frame in
                            RemoteImage(url: appState.client?.previewFrameURL(filename: frame.filename), maxPixelSize: 160)
                                .frame(width: width / CGFloat(stripFrames.count))
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // Dim the un-played remainder subtly so the played portion reads brighter.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.12))

                // Event marker (orange).
                if duration > 0, let es = eventStart {
                    let frac = CGFloat(min(max((es - windowStart) / (windowEnd - windowStart), 0), 1))
                    Rectangle().fill(GlassTheme.orange)
                        .frame(width: 3)
                        .overlay(alignment: .top) {
                            Circle().fill(GlassTheme.orange).frame(width: 8, height: 8).offset(y: -5)
                        }
                        .offset(x: width * frac - 1.5)
                        .allowsHitTesting(false)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }

                // Playhead (white).
                Rectangle().fill(.white)
                    .frame(width: 3)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: width * playheadFraction - 1.5)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isSliding = true
                        let frac = min(max(value.location.x / width, 0), 1)
                        currentTime = Double(frac) * max(duration, 1)
                    }
                    .onEnded { value in
                        let frac = min(max(value.location.x / width, 0), 1)
                        let target = Double(frac) * max(duration, 1)
                        currentTime = target
                        model.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                           toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
                        isSliding = false
                    }
            )
        }
        .frame(height: 64)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: GlassTheme.Space.m) {
            Button {
                Haptics.tap()
                if isPlaying { model.pause() } else { model.play() }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .black))
                    .frame(width: 40, height: 40)
                    .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                    .foregroundStyle(GlassTheme.primary)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Text(formatTime(windowStart + currentTime))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(GlassTheme.primary)

            Spacer(minLength: GlassTheme.Space.s)

            if let es = eventStart {
                Button { jumpToEvent(es) } label: {
                    Label("Jump to Event", systemImage: "scope")
                        .font(.footnote.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(GlassTheme.accent)
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
    }

    private func jumpToEvent(_ eventStartTime: Double) {
        guard let player = model.player else { return }
        Haptics.select()
        let offset = max(0, eventStartTime - windowStart - 3)
        player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                    toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
        currentTime = offset
        model.play()
    }

    private func formatTime(_ epoch: Double) -> String {
        Date(timeIntervalSince1970: epoch).formatted(date: .omitted, time: .shortened)
    }
}
