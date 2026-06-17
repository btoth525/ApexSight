import SwiftUI
import AVKit
import AVFoundation

struct EventDetailView: View {
    @EnvironmentObject private var appState: AppState
    let event: FrigateEvent
    @State private var actionFeedback: String?
    @State private var actionIsError = false
    @State private var isActing = false
    @StateObject private var clipModel = ClipPlayerModel()
    @State private var isDownloading = false
    @State private var downloadFeedback: String?
    @State private var mediaMode: MediaMode = .video
    @State private var genAIDescription: String?
    @State private var isEditingAIDescription = false
    @State private var isRegeneratingAI = false
    @State private var editedAIDescription = ""
    @State private var showSimilarSheet = false
    @State private var similarEvents: [FrigateEvent] = []
    @State private var similarError: String?
    @State private var isLoadingSimilar = false
    @State private var createTrigger: NotificationTrigger?

    private enum MediaMode: String, CaseIterable {
        case video = "Video"
        case snapshot = "Snapshot"
        case history = "History"
    }

    private var hasClip: Bool { event.hasClip != false }

    /// What the fullscreen viewer should show: the live clip while in Video mode, else the snapshot.
    private var fullscreenMedia: FullscreenMediaView.Media? {
        if hasClip, mediaMode == .video, let player = clipModel.player {
            return .player(player)
        }
        if mediaMode == .history { return nil }
        if let url = appState.client?.eventSnapshotURL(id: event.id) {
            return .image(url)
        }
        return nil
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    heroCard
                    if let genAIDescription { aiCard(genAIDescription) }
                    detailsCard
                    actionsCard
                }
                .padding(16)
            }
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task(id: event.id) {
            genAIDescription = try? await appState.client?.eventDescription(id: event.id)
        }
        .sheet(isPresented: $showSimilarSheet) {
            SimilarEventsSheet(sourceEvent: event, events: similarEvents, errorMessage: similarError)
                .environmentObject(appState)
        }
        .sheet(item: $createTrigger) { trigger in
            TriggerEditorView(store: appState.triggerStore, existing: trigger)
                .environmentObject(appState)
        }
    }

    private func aiCard(_ text: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.purple)
                    Text("AI Description")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    Button {
                        editedAIDescription = text
                        isEditingAIDescription = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(GlassTheme.purple)
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await regenerateAIDescription() }
                    } label: {
                        if isRegeneratingAI {
                            ProgressView().tint(GlassTheme.purple).scaleEffect(0.75)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(GlassTheme.purple)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRegeneratingAI)
                }
                if isEditingAIDescription {
                    TextEditor(text: $editedAIDescription)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(GlassTheme.secondary)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                    HStack(spacing: 10) {
                        Button("Cancel") {
                            isEditingAIDescription = false
                        }
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
                        Spacer()
                        Button("Save") {
                            Task { await saveAIDescription() }
                        }
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(GlassTheme.purple)
                    }
                } else {
                    Text(text)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(GlassTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var heroCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Media", selection: $mediaMode) {
                    ForEach(MediaMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mediaMode) { _, mode in
                    if mode == .video { clipModel.play() } else { clipModel.pause() }
                }

                ZStack {
                    if hasClip, mediaMode == .video, let player = clipModel.player {
                        ZoomableClipPlayer(player: player)
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                    } else if mediaMode == .history, let startTime = event.startTime {
                        RecordingContextPlayerView(
                            camera: event.camera,
                            centerTime: startTime,
                            eventStart: event.startTime,
                            eventEnd: event.endTime
                        )
                        .frame(maxWidth: .infinity)
                    } else if let url = appState.client?.eventSnapshotURL(id: event.id) {
                        ZoomableScrollView {
                            RemoteImage(url: url, contentMode: .fit)
                        }
                        .frame(height: 300)
                        .frame(maxWidth: .infinity)
                    } else {
                        Color.black
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                    }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .expandableMedia(fullscreenMedia)

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(GlassTheme.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("\(titleize(event.camera)) · \(timestamp(event.startTime))")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if hasClip {
                        Button {
                            Task { await downloadClip() }
                        } label: {
                            Image(systemName: isDownloading ? "arrow.down.circle" : "arrow.down.circle.fill")
                                .font(.system(size: 26, weight: .black))
                                .foregroundStyle(GlassTheme.cyan)
                                .symbolEffect(.pulse, isActive: isDownloading)
                        }
                        .buttonStyle(.plain)
                        .disabled(isDownloading)
                    }
                }

                if let downloadFeedback {
                    Text(downloadFeedback)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.green)
                }
            }
            .task(id: event.id) {
                // Keyed to THIS event + a forced load so a reused detail view can never
                // play the previous event's clip.
                guard hasClip, let client = appState.client else { clipModel.stop(); return }
                // Frigate's purpose-built event VOD endpoint (`/vod/event/<id>/master.m3u8`) —
                // the documented, iOS-recommended way to play an event back.
                clipModel.load(client: client, url: client.eventVodURL(id: event.id))
            }
            .onDisappear { clipModel.stop() }
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
                    if let face = event.recognizedFace {
                        metric("Face", value: "👤 \(titleize(face))")
                    } else if let sub = event.subLabel, !sub.isEmpty {
                        metric("Sub-Label", value: "\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(sub))")
                    }
                    if let plate = event.recognizedLicensePlate, !plate.isEmpty {
                        metric("Plate", value: "🔎 \(plate.uppercased())")
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
                        .foregroundStyle(actionIsError ? GlassTheme.red : GlassTheme.green)
                }

                actionButton("Retain Event", icon: "pin.fill", tint: GlassTheme.blue, isLoading: isActing) {
                    Task { await retainEvent() }
                }

                actionButton("Find Similar Events", icon: "sparkle.magnifyingglass", tint: GlassTheme.purple, isLoading: isLoadingSimilar) {
                    Task { await loadSimilarEvents() }
                }

                actionButton("Create Notification Trigger", icon: "bell.badge.fill", tint: GlassTheme.orange) {
                    var trigger = NotificationTrigger(name: "\(titleize(event.displayLabel)) on \(titleize(event.camera))")
                    trigger.cameras = [event.camera]
                    trigger.labels = [event.label]
                    createTrigger = trigger
                }

                if let camera = appState.cameras.first(where: { $0.name == event.camera }) {
                    NavigationLink {
                        LiveStreamView(camera: camera)
                    } label: {
                        HStack {
                            Image(systemName: "video.fill")
                                .font(.system(size: 15, weight: .heavy))
                            Text("Open Live Camera")
                                .font(.system(size: 15, weight: .black))
                            Spacer()
                        }
                        .foregroundStyle(GlassTheme.cyan)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .background(GlassTheme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, tint: Color, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .heavy))
                Text(title)
                    .font(.system(size: 15, weight: .black))
                Spacer()
                if isLoading {
                    ProgressView().tint(tint)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        // Per-action: only this button disables while it's working, not the whole list.
        .disabled(isLoading)
    }

    /// Shows a transient feedback line (auto-clears) in the Actions card.
    private func showFeedback(_ message: String, isError: Bool) {
        actionFeedback = message
        actionIsError = isError
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if actionFeedback == message { actionFeedback = nil }
        }
    }

    private func retainEvent() async {
        guard let client = appState.client else { return }
        isActing = true
        defer { isActing = false }
        do {
            try await client.retainEvent(id: event.id)
            showFeedback("Event retained.", isError: false)
        } catch {
            showFeedback(error.localizedDescription, isError: true)
        }
    }

    private func saveAIDescription() async {
        guard let client = appState.client else { return }
        do {
            try await client.setEventDescription(id: event.id, description: editedAIDescription)
            genAIDescription = editedAIDescription.isEmpty ? nil : editedAIDescription
            isEditingAIDescription = false
        } catch {
            showFeedback(error.localizedDescription, isError: true)
        }
    }

    private func regenerateAIDescription() async {
        guard let client = appState.client else { return }
        isRegeneratingAI = true
        defer { isRegeneratingAI = false }
        do {
            // Server-side generation is async — request it, then re-fetch shortly after
            // (the final text may still arrive later via a normal refresh).
            try await client.regenerateEventDescription(id: event.id)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let fresh = try? await client.eventDescription(id: event.id) {
                genAIDescription = fresh
            }
            showFeedback("Regeneration requested.", isError: false)
        } catch {
            showFeedback(error.localizedDescription, isError: true)
        }
    }

    private func loadSimilarEvents() async {
        guard let client = appState.client else { return }
        isLoadingSimilar = true
        defer { isLoadingSimilar = false }
        do {
            similarEvents = try await client.findSimilar(eventId: event.id)
            similarError = nil
        } catch {
            similarEvents = []
            similarError = error.localizedDescription
        }
        showSimilarSheet = true
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
