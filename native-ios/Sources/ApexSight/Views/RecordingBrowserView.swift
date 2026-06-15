import AVFoundation
import AVKit
import SwiftUI

struct RecordingBrowserView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @State private var selectedDate = Date()
    @State private var recordings: [FrigateRecording] = []
    @State private var selectedRecording: FrigateRecording?
    @State private var player: AVPlayer?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isDownloading = false
    @State private var downloadFeedback: String?
    @State private var selectedHour: Int?

    private let calendar = Calendar.current

    private struct HourBucket: Identifiable {
        let hour: Int
        let segmentCount: Int
        let motion: Double
        var id: Int { hour }
    }

    private var hourBuckets: [HourBucket] {
        var counts = [Int: (segments: Int, motion: Double)]()
        for recording in recordings {
            guard let start = recording.startTime else { continue }
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: start))
            var bucket = counts[hour] ?? (0, 0)
            bucket.segments += 1
            bucket.motion = max(bucket.motion, recording.motion ?? 0)
            counts[hour] = bucket
        }
        return (0..<24).map { hour in
            let bucket = counts[hour] ?? (0, 0)
            return HourBucket(hour: hour, segmentCount: bucket.segments, motion: bucket.motion)
        }
    }

    private var displayedRecordings: [FrigateRecording] {
        guard let selectedHour else { return recordings }
        return recordings.filter { recording in
            guard let start = recording.startTime else { return false }
            return calendar.component(.hour, from: Date(timeIntervalSince1970: start)) == selectedHour
        }
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle
                    datePicker
                    if isLoading {
                        ProgressView().tint(GlassTheme.cyan).frame(maxWidth: .infinity)
                    } else if recordings.isEmpty {
                        noRecordingsCard
                    } else {
                        timelineCard
                        if let recording = selectedRecording, let player {
                            playerCard(recording: recording, player: player)
                        }
                        recordingList
                    }
                }
                .padding(18)
            }
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task { await loadRecordings(for: selectedDate) }
        .onChange(of: selectedDate) { _, date in
            Task { await loadRecordings(for: date) }
        }
    }

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
            VStack(spacing: 14) {
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
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(GlassTheme.primary)
                        if Calendar.current.isDateInToday(selectedDate) {
                            Text("Today")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(GlassTheme.cyan)
                        }
                    }
                    Spacer()
                    Button { shiftDate(by: 1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Calendar.current.isDateInToday(selectedDate) ? GlassTheme.tertiary : GlassTheme.cyan)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(Calendar.current.isDateInToday(selectedDate))
                }
                DatePicker("Pick date", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(GlassTheme.cyan)
            }
        }
    }

    private func shiftDate(by days: Int) {
        guard let newDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate),
              newDate <= Date() else { return }
        selectedDate = newDate
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

    private func playerCard(recording: FrigateRecording, player: AVPlayer) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Playing Clip")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    if let start = recording.startTime, let end = recording.endTime {
                        Text(formatDuration(end - start))
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(GlassTheme.cyan)
                    }
                }
                PiPPlayerView(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    Task { await downloadRecording(recording) }
                } label: {
                    HStack(spacing: 6) {
                        if isDownloading {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14, weight: .black))
                        }
                        Text(isDownloading ? "Saving…" : "Save to Photos")
                            .font(.system(size: 13, weight: .black))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(GlassTheme.cyan, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)

                if let downloadFeedback {
                    Text(downloadFeedback)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.green)
                }
            }
        }
    }

    private func downloadRecording(_ recording: FrigateRecording) async {
        guard let client = appState.client,
              let start = recording.startTime,
              let end = recording.endTime else { return }
        isDownloading = true
        downloadFeedback = nil
        defer { isDownloading = false }
        do {
            let url = client.recordingClipURL(camera: camera.name, start: start, end: end)
            try await ClipDownloader.downloadToPhotos(url: url, client: client, fileName: "Apex-\(camera.name)-\(Int(start))")
            downloadFeedback = "Saved to Photos."
        } catch {
            downloadFeedback = error.localizedDescription
        }
    }

    private var timelineCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Timeline")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    if let selectedHour {
                        Button {
                            withAnimation { self.selectedHour = nil }
                        } label: {
                            Text("\(hourLabel(selectedHour)) ✕")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(GlassTheme.cyan, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("Tap an hour")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }

                let maxCount = max(1, hourBuckets.map(\.segmentCount).max() ?? 1)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(hourBuckets) { bucket in
                        timelineBar(bucket, maxCount: maxCount)
                    }
                }
                .frame(height: 64)

                HStack {
                    Text("12a")
                    Spacer()
                    Text("6a")
                    Spacer()
                    Text("12p")
                    Spacer()
                    Text("6p")
                    Spacer()
                    Text("11p")
                }
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(GlassTheme.tertiary)
            }
        }
    }

    private func timelineBar(_ bucket: HourBucket, maxCount: Int) -> some View {
        let isActive = bucket.segmentCount > 0
        let isSelected = selectedHour == bucket.hour
        let fraction = isActive ? max(0.18, Double(bucket.segmentCount) / Double(maxCount)) : 0.05
        let tint = bucket.motion > 0.3 ? GlassTheme.orange : GlassTheme.cyan
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isActive ? (isSelected ? Color.white : tint) : Color.white.opacity(0.08))
                    .frame(height: 64 * fraction)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(GlassTheme.cyan, lineWidth: 1.5)
                        }
                    }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isActive else { return }
                withAnimation { selectedHour = isSelected ? nil : bucket.hour }
            }
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12 AM" }
        if hour < 12 { return "\(hour) AM" }
        if hour == 12 { return "12 PM" }
        return "\(hour - 12) PM"
    }

    private var recordingList: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(displayedRecordings.count) segments\(selectedHour != nil ? " · \(hourLabel(selectedHour!))" : "")")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                VStack(spacing: 8) {
                    ForEach(displayedRecordings) { recording in
                        recordingRow(recording)
                    }
                }
            }
        }
    }

    private func recordingRow(_ recording: FrigateRecording) -> some View {
        let isSelected = selectedRecording?.id == recording.id
        return Button {
            selectRecording(recording)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(isSelected ? GlassTheme.cyan : GlassTheme.primary.opacity(0.6))

                VStack(alignment: .leading, spacing: 4) {
                    if let start = recording.startTime {
                        Text(Date(timeIntervalSince1970: start), style: .time)
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(GlassTheme.primary)
                    }
                    HStack(spacing: 8) {
                        if let start = recording.startTime, let end = recording.endTime {
                            Text(formatDuration(end - start))
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(GlassTheme.secondary)
                        }
                        if let motion = recording.motion, motion > 0 {
                            Label(String(format: "%.0f%% motion", motion * 100), systemImage: "figure.walk")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(GlassTheme.orange)
                        }
                        if let objects = recording.objects, objects > 0 {
                            Label("\(Int(objects)) objects", systemImage: "eye.fill")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(GlassTheme.blue)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(GlassTheme.secondary)
            }
            .padding(12)
            .background(isSelected ? GlassTheme.cyan.opacity(0.12) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func loadRecordings(for date: Date) async {
        guard let client = appState.client else { return }
        isLoading = true
        errorMessage = nil
        player?.pause()
        player = nil
        selectedRecording = nil
        selectedHour = nil
        downloadFeedback = nil

        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        do {
            recordings = try await client.recordings(camera: camera.name, after: startOfDay, end: endOfDay)
                .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        } catch {
            errorMessage = error.localizedDescription
            recordings = []
        }
        isLoading = false
    }

    private func selectRecording(_ recording: FrigateRecording) {
        guard let client = appState.client,
              let start = recording.startTime,
              let end = recording.endTime else { return }

        player?.pause()
        downloadFeedback = nil
        selectedRecording = recording
        let url = client.recordingClipURL(camera: camera.name, start: start, end: end)
        let item = client.playerItem(for: url)
        let newPlayer = AVPlayer(playerItem: item)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        newPlayer.play()
        player = newPlayer
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
