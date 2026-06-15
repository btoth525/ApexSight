import AVFoundation
import AVKit
import SwiftUI

struct RecordingBrowserView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @State private var selectedDate = Date()
    @State private var recordings: [FrigateRecording] = []
    @State private var dayEvents: [FrigateEvent] = []
    @State private var player: AVPlayer?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isDownloading = false
    @State private var downloadFeedback: String?

    // Scrubber state
    @State private var scrubFraction: Double = 0      // 0…1 across the selected day
    @State private var isScrubbing = false
    @State private var playingTime: Double?           // epoch currently playing

    private let calendar = Calendar.current
    private let windowSeconds: Double = 300           // 5-minute clip per scrub

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle
                    datePicker
                    if isLoading {
                        ProgressView().tint(GlassTheme.cyan).frame(maxWidth: .infinity).padding(.top, 30)
                    } else {
                        scrubberCard
                        if let player {
                            playerCard(player)
                        }
                        if recordings.isEmpty {
                            noRecordingsCard
                        } else {
                            recordingList
                        }
                    }
                }
                .padding(18)
            }
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task { await loadDay(selectedDate) }
        .onChange(of: selectedDate) { _, date in
            Task { await loadDay(date) }
        }
    }

    // MARK: - Header

    private var sectionTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleize(camera.name))
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(GlassTheme.primary)
            Text("Recording timeline")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    private var datePicker: some View {
        GlassCard {
            HStack {
                Button { shiftDate(by: -1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.cyan)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                VStack(spacing: 2) {
                    Text(selectedDate, style: .date)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    if calendar.isDateInToday(selectedDate) {
                        Text("Today").font(.system(size: 11, weight: .heavy)).foregroundStyle(GlassTheme.cyan)
                    }
                }
                Spacer()
                Button { shiftDate(by: 1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(calendar.isDateInToday(selectedDate) ? GlassTheme.tertiary : GlassTheme.cyan)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(calendar.isDateInToday(selectedDate))
            }
        }
    }

    private func shiftDate(by days: Int) {
        guard let newDate = calendar.date(byAdding: .day, value: days, to: selectedDate),
              newDate <= Date() else { return }
        selectedDate = newDate
    }

    // MARK: - Scrubber

    private var scrubberCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Timeline")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    Text(scrubTimeLabel)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(GlassTheme.cyan)
                        .monospacedDigit()
                }

                scrubberTrack
                    .frame(height: 92)

                HStack {
                    Text("12a"); Spacer(); Text("6a"); Spacer()
                    Text("12p"); Spacer(); Text("6p"); Spacer(); Text("11p")
                }
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(GlassTheme.tertiary)

                legend
            }
        }
    }

    private var scrubberTrack: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                // Track background
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.35))

                // Recording coverage + colored event ticks
                Canvas { ctx, size in
                    let dayStart = calendar.startOfDay(for: selectedDate).timeIntervalSince1970

                    // coverage strip along the bottom
                    for rec in recordings {
                        guard let s = rec.startTime else { continue }
                        let f = (s - dayStart) / 86400
                        guard f >= 0, f <= 1 else { continue }
                        let x = f * size.width
                        let cov = CGRect(x: x, y: size.height - 7, width: max(1, size.width / 24 / 12), height: 6)
                        ctx.fill(Path(cov), with: .color(.white.opacity(0.16)))
                    }

                    // event ticks, colored by object
                    for e in dayEvents {
                        guard let s = e.startTime else { continue }
                        let f = (s - dayStart) / 86400
                        guard f >= 0, f <= 1 else { continue }
                        let x = f * size.width
                        let rect = CGRect(x: x - 1.25, y: 10, width: 2.5, height: size.height - 24)
                        ctx.fill(Path(rect), with: .color(color(for: e.label)))
                    }
                }
                .padding(.horizontal, 2)

                // Playhead
                let px = CGFloat(scrubFraction) * w
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: h)
                    .offset(x: px.clampedX(in: w))
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .overlay { Circle().stroke(GlassTheme.cyan, lineWidth: 3) }
                    .offset(x: px.clampedX(in: w) - 8, y: -8)
                    .shadow(radius: 3)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        scrubFraction = Double(max(0, min(value.location.x / w, 1)))
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        playFromScrub()
                    }
            )
        }
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

    private func legendDot(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 10, weight: .heavy)).foregroundStyle(GlassTheme.secondary)
        }
    }

    private var scrubTimeLabel: String {
        let dayStart = calendar.startOfDay(for: selectedDate).timeIntervalSince1970
        let t = dayStart + scrubFraction * 86400
        return Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(playingTime != nil ? "Playing from \(Date(timeIntervalSince1970: playingTime!).formatted(date: .omitted, time: .shortened))" : "Playing Clip")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                }
                PiPPlayerView(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    Task { await downloadCurrent() }
                } label: {
                    HStack(spacing: 6) {
                        if isDownloading { ProgressView().tint(.black) }
                        else { Image(systemName: "arrow.down.circle.fill").font(.system(size: 14, weight: .black)) }
                        Text(isDownloading ? "Saving…" : "Save to Photos")
                            .font(.system(size: 13, weight: .black))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(GlassTheme.cyan, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDownloading || playingTime == nil)

                if let downloadFeedback {
                    Text(downloadFeedback)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.green)
                }
            }
        }
    }

    private var noRecordingsCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(GlassTheme.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No recordings")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Text("No recordings found for this date.")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GlassTheme.secondary)
                }
            }
        }
    }

    // MARK: - Event jump list (recent detections that day)

    private var recordingList: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(dayEvents.isEmpty ? "\(recordings.count) recording segments" : "\(dayEvents.count) detections")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                if dayEvents.isEmpty {
                    Text("Scrub the timeline above to play any moment.")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
                } else {
                    VStack(spacing: 8) {
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
            HStack(spacing: 12) {
                Circle()
                    .fill(color(for: event.label))
                    .frame(width: 10, height: 10)
                if let url = appState.client?.eventThumbnailURL(id: event.id) {
                    RemoteImage(url: url, contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    if let start = event.startTime {
                        Text(Date(timeIntervalSince1970: start), style: .time)
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(GlassTheme.cyan)
            }
            .padding(10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data + playback

    private func loadDay(_ date: Date) async {
        guard let client = appState.client else { return }
        isLoading = true
        errorMessage = nil
        player?.pause()
        player = nil
        playingTime = nil
        downloadFeedback = nil

        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        async let recs = client.recordings(camera: camera.name, after: startOfDay, end: endOfDay)
        async let evs = client.events(
            camera: camera.name, after: startOfDay, before: endOfDay, limit: 500
        )

        recordings = ((try? await recs) ?? []).sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        dayEvents = (try? await evs) ?? []

        // Park the playhead on the most recent detection for a useful default.
        if let latest = dayEvents.compactMap(\.startTime).max() {
            scrubFraction = (latest - startOfDay.timeIntervalSince1970) / 86400
        }
        isLoading = false
    }

    private func playFromScrub() {
        let dayStart = calendar.startOfDay(for: selectedDate).timeIntervalSince1970
        let time = dayStart + scrubFraction * 86400
        let cappedNow = Date().timeIntervalSince1970 - windowSeconds
        playFrom(time: min(time, cappedNow))
    }

    private func playFrom(time: Double) {
        guard let client = appState.client else { return }
        let dayStart = calendar.startOfDay(for: selectedDate).timeIntervalSince1970
        scrubFraction = max(0, min((time - dayStart) / 86400, 1))

        player?.pause()
        downloadFeedback = nil
        playingTime = time
        let url = client.recordingClipURL(camera: camera.name, start: time, end: time + windowSeconds)
        let item = client.playerItem(for: url)
        let newPlayer = AVPlayer(playerItem: item)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        newPlayer.play()
        player = newPlayer
    }

    private func downloadCurrent() async {
        guard let client = appState.client, let start = playingTime else { return }
        isDownloading = true
        downloadFeedback = nil
        defer { isDownloading = false }
        do {
            let url = client.recordingClipURL(camera: camera.name, start: start, end: start + windowSeconds)
            try await ClipDownloader.downloadToPhotos(url: url, client: client, fileName: "Apex-\(camera.name)-\(Int(start))")
            downloadFeedback = "Saved to Photos."
        } catch {
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
