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

    private var windowStart: Double { centerTime - windowSeconds / 2 }
    private var windowEnd: Double { centerTime + windowSeconds / 2 }

    var body: some View {
        VStack(spacing: 10) {
            if let player = model.player {
                ZoomableClipPlayer(player: player)
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                        guard !isSliding else { return }
                        currentTime = player.currentTime().seconds
                        if let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                            duration = dur
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black)
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .overlay { ProgressView().tint(GlassTheme.cyan) }
            }

            // Scrub bar with event markers
            VStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                        isSliding = editing
                        if !editing, let player = model.player {
                            let target = CMTime(seconds: currentTime, preferredTimescale: 600)
                            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                    .tint(GlassTheme.cyan)

                    // Event start/end markers
                    if duration > 0 {
                        if let es = eventStart {
                            let evOffset = es - windowStart
                            let fraction = evOffset / (windowEnd - windowStart)
                            let clamped = max(0, min(1, fraction))
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(GlassTheme.orange)
                                    .frame(width: 3, height: 16)
                                    .offset(x: geo.size.width * clamped - 1.5, y: -2)
                            }
                            .frame(height: 16)
                            .allowsHitTesting(false)
                        }
                    }
                }

                HStack {
                    Text(formatTime(windowStart + currentTime))
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(GlassTheme.secondary)
                    Spacer()
                    if let es = eventStart {
                        Button {
                            jumpToEvent(es)
                        } label: {
                            Label("Jump to Event", systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(GlassTheme.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text(formatTime(windowStart + duration))
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
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
                    _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
        .onDisappear { model.pause() }
    }

    private func jumpToEvent(_ eventStartTime: Double) {
        guard let player = model.player else { return }
        let offset = max(0, eventStartTime - windowStart - 3)
        let target = CMTime(seconds: offset, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = offset
    }

    private func formatTime(_ epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        return date.formatted(date: .omitted, time: .shortened)
    }
}
