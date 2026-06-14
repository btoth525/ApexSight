import SwiftUI
import AVKit

@MainActor
final class ReviewViewModel: ObservableObject {
    @Published var events: [FrigateEvent] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var eventsByDate: [(String, [FrigateEvent])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let grouped = Dictionary(grouping: events) { formatter.string(from: $0.startDate) }
        return grouped
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.startTime > $1.startTime }) }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            events = try await FrigateAPI.shared.fetchEvents(limit: 100)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func markReviewed(_ event: FrigateEvent) async {
        do {
            try await FrigateAPI.shared.markEventReviewed(id: event.id)
            events.removeAll { $0.id == event.id }
        } catch {}
    }
}

struct ReviewView: View {
    @StateObject private var vm = ReviewViewModel()
    @State private var playingClipURL: URL?

    var body: some View {
        Group {
            if vm.isLoading && vm.events.isEmpty {
                ProgressView("Loading events…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage, vm.events.isEmpty {
                ContentUnavailableView {
                    Label("No Events", systemImage: "bell.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await vm.load() } }
                }
            } else {
                List {
                    ForEach(vm.eventsByDate, id: \.0) { dateString, eventsInDay in
                        Section(dateString) {
                            ForEach(eventsInDay) { event in
                                EventRow(event: event) {
                                    if let url = FrigateAPI.shared.eventClipURL(id: event.id) {
                                        playingClipURL = url
                                    }
                                } onMarkReviewed: {
                                    Task { await vm.markReviewed(event) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await vm.load() }
            }
        }
        .task { await vm.load() }
        .sheet(item: $playingClipURL) { url in
            VideoPlayerSheet(url: url)
        }
    }
}

// MARK: - EventRow

private struct EventRow: View {
    let event: FrigateEvent
    let onPlay: () -> Void
    let onMarkReviewed: () -> Void

    private var timeString: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: event.startDate)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Snapshot thumbnail
            AsyncImage(url: FrigateAPI.shared.eventSnapshotURL(id: event.id)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Rectangle().fill(Color.gray.opacity(0.3))
                        .overlay(Image(systemName: "photo").foregroundColor(.gray))
                default:
                    Rectangle().fill(Color.gray.opacity(0.2)).overlay(ProgressView())
                }
            }
            .frame(width: 80, height: 50)
            .cornerRadius(8)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.label.capitalized)
                        .font(.subheadline.bold())
                    if let score = event.score {
                        Text(String(format: "%.0f%%", score * 100))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(scoreColor(score).opacity(0.2))
                            .foregroundColor(scoreColor(score))
                            .clipShape(Capsule())
                    }
                }
                Text(event.camera.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(timeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if event.hasClip {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onMarkReviewed) {
                Label("Reviewed", systemImage: "checkmark")
            }
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        score >= 0.8 ? .red : score >= 0.5 ? .orange : .yellow
    }
}

// MARK: - Video clip sheet

private struct VideoPlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .onAppear { AVPlayer(url: url).play() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - URL Identifiable

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
