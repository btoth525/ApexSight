import SwiftUI
import AVKit

struct RecordingBrowserView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @State private var selectedDate = Date()
    @State private var recordings: [FrigateRecording] = []
    @State private var selectedRecording: FrigateRecording?
    @State private var player: AVPlayer?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let calendar = Calendar.current

    var body: some View {
        ZStack {
            GlassTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle
                    datePicker
                    if isLoading {
                        ProgressView().tint(GlassTheme.cyan).frame(maxWidth: .infinity)
                    } else if recordings.isEmpty {
                        noRecordingsCard
                    } else {
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
        .task { await loadRecordings(for: selectedDate) }
        .onChange(of: selectedDate) { _, date in
            Task { await loadRecordings(for: date) }
        }
    }

    private var sectionTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleize(camera.name))
                .font(.system(size: 28, weight: .900))
                .foregroundStyle(GlassTheme.primary)
            Text("Recording timeline")
                .font(.system(size: 13, weight: .800))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    private var datePicker: some View {
        GlassCard {
            DatePicker(
                "Recording date",
                selection: $selectedDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .tint(GlassTheme.cyan)
        }
    }

    private var noRecordingsCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 24, weight: .700))
                    .foregroundStyle(GlassTheme.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No recordings")
                        .font(.system(size: 16, weight: .900))
                        .foregroundStyle(GlassTheme.primary)
                    Text("No recordings found for this date.")
                        .font(.system(size: 13, weight: .700))
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
                        .font(.system(size: 16, weight: .900))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    if let start = recording.startTime, let end = recording.endTime {
                        Text(formatDuration(end - start))
                            .font(.system(size: 13, weight: .800))
                            .foregroundStyle(GlassTheme.cyan)
                    }
                }
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var recordingList: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(recordings.count) segments")
                    .font(.system(size: 16, weight: .900))
                    .foregroundStyle(GlassTheme.primary)
                VStack(spacing: 8) {
                    ForEach(recordings) { recording in
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
                    .font(.system(size: 24, weight: .700))
                    .foregroundStyle(isSelected ? GlassTheme.cyan : GlassTheme.primary.opacity(0.6))

                VStack(alignment: .leading, spacing: 4) {
                    if let start = recording.startTime {
                        Text(Date(timeIntervalSince1970: start), style: .time)
                            .font(.system(size: 15, weight: .900))
                            .foregroundStyle(GlassTheme.primary)
                    }
                    HStack(spacing: 8) {
                        if let start = recording.startTime, let end = recording.endTime {
                            Text(formatDuration(end - start))
                                .font(.system(size: 12, weight: .800))
                                .foregroundStyle(GlassTheme.secondary)
                        }
                        if let motion = recording.motion, motion > 0 {
                            Label(String(format: "%.0f%% motion", motion * 100), systemImage: "figure.walk")
                                .font(.system(size: 11, weight: .800))
                                .foregroundStyle(GlassTheme.orange)
                        }
                        if let objects = recording.objects, objects > 0 {
                            Label("\(Int(objects)) objects", systemImage: "eye.fill")
                                .font(.system(size: 11, weight: .800))
                                .foregroundStyle(GlassTheme.blue)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .700))
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
        selectedRecording = recording
        let url = client.recordingHLSURL(camera: camera.name, start: start, end: end)
        let item = client.playerItem(for: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.play()
        player = newPlayer
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
