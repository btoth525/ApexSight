import SwiftUI
import AVKit

struct EventDetailView: View {
    @EnvironmentObject private var appState: AppState
    let event: FrigateEvent
    @State private var actionFeedback: String?
    @State private var isActing = false
    @State private var showDeleteConfirm = false
    @State private var showFalsePositiveConfirm = false
    @State private var clipPlayer: AVPlayer?
    @State private var isDownloading = false
    @State private var downloadFeedback: String?

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    detailsCard
                    if event.hasClip != false { clipCard }
                    actionsCard
                }
                .padding(18)
            }
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this event?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteEvent() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Mark as false positive?", isPresented: $showFalsePositiveConfirm, titleVisibility: .visible) {
            Button("Mark False Positive", role: .destructive) { Task { await markFalsePositive() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var heroCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                if let url = appState.client?.eventSnapshotURL(id: event.id) {
                    RemoteImage(url: url)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(GlassTheme.primary)
                Text("\(titleize(event.camera)) · \(timestamp(event.startTime))")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(GlassTheme.secondary)
            }
        }
    }

    private var detailsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Details")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    metric("Confidence", value: confidence)
                    metric("Camera", value: titleize(event.camera))
                    if let sub = event.subLabel, !sub.isEmpty {
                        metric("Sub-Label", value: "\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(sub))")
                    }
                    metric("Clip", value: event.hasClip == false ? "No" : "Available")
                    metric("Snapshot", value: event.hasSnapshot == false ? "No" : "Available")
                    if let start = event.startTime, let end = event.endTime {
                        metric("Duration", value: formatDuration(end - start))
                    }
                }

                if let zones = event.zones, !zones.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(zones, id: \.self) { zone in
                                Text(titleize(zone))
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(GlassTheme.cyan)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(GlassTheme.cyan.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private var clipCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Clip")
                        .font(.system(size: 21, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    Button {
                        Task { await downloadClip() }
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(GlassTheme.cyan, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloading)
                }

                if let downloadFeedback {
                    Text(downloadFeedback)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.green)
                }

                if let clipPlayer {
                    PiPPlayerView(player: clipPlayer)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .task {
                guard clipPlayer == nil,
                      let clipURL = appState.client?.eventHLSURL(id: event.id),
                      let item = appState.client?.playerItem(for: clipURL) else { return }
                clipPlayer = AVPlayer(playerItem: item)
            }
            .onDisappear { clipPlayer?.pause() }
        }
    }

    private func downloadClip() async {
        guard let client = appState.client else { return }
        isDownloading = true
        downloadFeedback = nil
        defer { isDownloading = false }
        do {
            let url = client.eventClipURL(id: event.id)
            try await ClipDownloader.downloadToPhotos(url: url, client: client, fileName: "Apex-\(event.id)")
            downloadFeedback = "Saved to Photos."
        } catch {
            downloadFeedback = error.localizedDescription
        }
    }

    private var actionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Actions")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                if let feedback = actionFeedback {
                    Text(feedback)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(GlassTheme.green)
                }

                actionButton("Retain Event", icon: "pin.fill", tint: GlassTheme.blue) {
                    Task { await retainEvent() }
                }
                actionButton("Mark False Positive", icon: "xmark.circle.fill", tint: GlassTheme.orange) {
                    showFalsePositiveConfirm = true
                }
                actionButton("Delete Event", icon: "trash.fill", tint: GlassTheme.red) {
                    showDeleteConfirm = true
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .heavy))
                Text(title)
                    .font(.system(size: 15, weight: .black))
                Spacer()
                if isActing {
                    ProgressView().tint(tint)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isActing)
    }

    private func retainEvent() async {
        guard let client = appState.client else { return }
        isActing = true
        defer { isActing = false }
        do {
            try await client.retainEvent(id: event.id)
            actionFeedback = "Event retained."
        } catch {
            actionFeedback = error.localizedDescription
        }
    }

    private func deleteEvent() async {
        guard let client = appState.client else { return }
        isActing = true
        defer { isActing = false }
        do {
            try await client.deleteEvent(id: event.id)
            actionFeedback = "Event deleted."
            appState.events.removeAll { $0.id == event.id }
        } catch {
            actionFeedback = error.localizedDescription
        }
    }

    private func markFalsePositive() async {
        guard let client = appState.client else { return }
        isActing = true
        defer { isActing = false }
        do {
            try await client.markFalsePositive(id: event.id)
            actionFeedback = "Marked as false positive."
        } catch {
            actionFeedback = error.localizedDescription
        }
    }

    private var confidence: String {
        guard let score = event.score ?? event.topScore else { return "n/a" }
        return "\(Int(score * 100))%"
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(GlassTheme.secondary)
            Text(value)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(GlassTheme.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func timestamp(_ epoch: Double?) -> String {
        guard let epoch else { return "Live" }
        return Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
