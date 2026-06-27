import SwiftUI
import AVFoundation

struct RecordingContextPlayerView: View {
    let camera: String
    let centerTime: Double
    let eventStart: Double?
    let eventEnd: Double?
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ClipPlayerModel()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isSliding = false

    private let windowSeconds: Double = 300  // ±5 minutes
    /// Allow ~1s of slop on seeks. Exact-frame seeks (.zero tolerance) force AVPlayer to
    /// decode all the way to the precise frame over HLS, which makes scrubbing feel sluggish;
    /// a small tolerance lands within a second and is dramatically snappier.
    private let seekTolerance = CMTime(seconds: 1, preferredTimescale: 600)

    private var windowStart: Double { centerTime - windowSeconds / 2 }
    private var windowEnd: Double { centerTime + windowSeconds / 2 }

    var body: some View {
        VStack(spacing: GlassTheme.Space.m) {
            LoadingClipPlayer(model: model)
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
                .cardStroke(GlassTheme.Radius.card)
                .task {
                    // Drive the scrub bar from the player clock. A Task loop (vs a
                    // Timer) is cancelled automatically when the view disappears.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if Task.isCancelled { break }
                        guard !isSliding, let player = model.player else { continue }
                        // Update duration FIRST so the clamp below uses the real range. Both
                        // values are NaN until the HLS item is ready — feeding NaN into the
                        // Slider or CMTime(seconds:) triggers a CoreGraphics NaN crash.
                        if let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                            duration = dur
                        }
                        let t = player.currentTime().seconds
                        if t.isFinite { currentTime = min(max(t, 0), max(duration, 1)) }
                    }
                }

            // Scrub bar with event marker
            VStack(spacing: GlassTheme.Space.s) {
                ZStack(alignment: .leading) {
                    Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                        isSliding = editing
                        if !editing, let player = model.player {
                            let target = CMTime(seconds: currentTime, preferredTimescale: 600)
                            player.seek(to: target, toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
                        }
                    }
                    .tint(GlassTheme.accent)

                    // Event start marker — a small semantic tick on the track.
                    if duration > 0, let es = eventStart {
                        let evOffset = es - windowStart
                        let fraction = evOffset / (windowEnd - windowStart)
                        let clamped = max(0, min(1, fraction))
                        GeometryReader { geo in
                            Capsule()
                                .fill(GlassTheme.orange)
                                .frame(width: 2, height: 14)
                                .overlay(alignment: .top) {
                                    Circle()
                                        .fill(GlassTheme.orange)
                                        .frame(width: 5, height: 5)
                                        .offset(y: -4)
                                }
                                .offset(x: geo.size.width * clamped - 1, y: -1)
                        }
                        .frame(height: 14)
                        .allowsHitTesting(false)
                    }
                }

                HStack(spacing: GlassTheme.Space.s) {
                    Text(formatTime(windowStart + currentTime))
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(GlassTheme.secondary)
                    Spacer(minLength: GlassTheme.Space.s)
                    if let es = eventStart {
                        Button {
                            jumpToEvent(es)
                        } label: {
                            Label("Jump to Event", systemImage: "scope")
                                .font(.footnote.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(GlassTheme.accent)
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                    Spacer(minLength: GlassTheme.Space.s)
                    Text(formatTime(windowStart + duration))
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(GlassTheme.secondary)
                }
            }
        }
        .task {
            guard let client = appState.client else { return }
            let url = client.recordingHLSURL(camera: camera, start: windowStart, end: windowEnd)
            model.loadIfNeeded(client: client, url: url)
            // Seek to event start offset
            if let es = eventStart {
                let offset = es - windowStart
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let player = model.player {
                    let target = CMTime(seconds: max(0, offset - 5), preferredTimescale: 600)
                    // Inside this async `.task`, AVPlayer.seek resolves to the async
                    // overload, so it must be awaited (and its Bool result discarded).
                    _ = await player.seek(to: target, toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
                }
            }
        }
        .onDisappear { model.stop() }
    }

    private func jumpToEvent(_ eventStartTime: Double) {
        guard let player = model.player else { return }
        let offset = max(0, eventStartTime - windowStart - 3)
        let target = CMTime(seconds: offset, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
        currentTime = offset
    }

    private func formatTime(_ epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        return date.formatted(date: .omitted, time: .shortened)
    }
}
