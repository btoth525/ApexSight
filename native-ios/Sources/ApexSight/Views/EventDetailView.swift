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
    @State private var isPreparingShare = false
    @State private var sharePayload: SharePayload?
    @State private var mediaMode: MediaMode = .video
    @State private var genAIDescription: String?
    @State private var isEditingAIDescription = false
    @State private var isRegeneratingAI = false
    @State private var isSavingAI = false
    @State private var editedAIDescription = ""
    @State private var showSimilarSheet = false
    @State private var similarEvents: [FrigateEvent] = []
    @State private var similarError: String?
    @State private var isLoadingSimilar = false
    @State private var createTrigger: NotificationTrigger?
    /// Distinguishes "no description yet" from "still fetching", so the AI card can show a
    /// skeleton on first load instead of silently appearing only once text arrives.
    @State private var isLoadingAIDescription = true
    /// iOS 27 on-device (Apple Intelligence) scene analysis of the event snapshot. Separate from
    /// the server-side Frigate GenAI description above — this never leaves the phone.
    @State private var onDeviceAnalysis: String?
    @State private var isAnalyzingOnDevice = false

    private enum MediaMode: String, CaseIterable {
        case video = "Video"
        case snapshot = "Snapshot"
        case history = "History"
    }

    private var hasClip: Bool { event.hasClip != false }

    /// What the fullscreen viewer shows — it MUST mirror exactly what the hero is
    /// rendering inline, so expand never opens the wrong medium (a snapshot while the
    /// user is watching the clip, or vice-versa).
    private var fullscreenMedia: FullscreenMediaView.Media? {
        switch mediaMode {
        case .video where hasClip:
            // A real clip is showing — expand opens the zoomable video. While it's still
            // loading (no player yet) we hide the button rather than fall back to the
            // snapshot, so expand never shows the wrong medium.
            guard let player = clipModel.player else { return nil }
            return .player(player)
        case .video, .snapshot:
            // Either Snapshot mode, or Video mode for a clip-less event — both render the
            // event snapshot inline, so expand opens that same image.
            guard let url = appState.client?.eventSnapshotURL(id: event.id) else { return nil }
            return .image(url)
        case .history:
            // The history scrubber has its own controls; nothing to expand.
            return nil
        }
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    heroCard
                    if let genAIDescription {
                        aiCard(genAIDescription)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if isLoadingAIDescription {
                        aiSkeletonCard
                    }
                    onDeviceAICard
                    detailsCard
                    actionsCard
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task(id: event.id) {
            isLoadingAIDescription = true
            let fetched = try? await appState.client?.eventDescription(id: event.id)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                genAIDescription = fetched
                isLoadingAIDescription = false
            }
        }
        .sheet(isPresented: $showSimilarSheet) {
            SimilarEventsSheet(sourceEvent: event, events: similarEvents, errorMessage: similarError)
                .environmentObject(appState)
        }
        .sheet(item: $createTrigger) { trigger in
            TriggerEditorView(store: appState.triggerStore, existing: trigger)
                .environmentObject(appState)
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
    }

    private func shareClip() async {
        guard let client = appState.client else { return }
        Haptics.tap()
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await ClipDownloader.downloadToTempFile(
                url: client.eventClipURL(id: event.id), client: client, fileName: "Apex-\(event.id)"
            )
            sharePayload = SharePayload(url: url)
        } catch {
            withAnimation { downloadFeedback = (error as? ClipDownloadError)?.errorDescription ?? "Could not prepare the clip." }
        }
    }

    /// iOS 27 on-device Apple Intelligence analysis of this event's snapshot. Only appears on
    /// hardware that can run it (and with the user's AI toggle on); the work runs entirely on the
    /// phone via FoundationModels image input — no frame leaves the device.
    @ViewBuilder
    private var onDeviceAICard: some View {
        if #available(iOS 27.0, *), AppleAI.visionAIAvailable {
            GlassCard {
                VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                    HStack(spacing: GlassTheme.Space.s) {
                        Image(systemName: "apple.intelligence")
                            .foregroundStyle(GlassTheme.accent)
                        SectionHeader("On-Device Analysis")
                        Spacer()
                    }
                    if let onDeviceAnalysis {
                        Text(onDeviceAnalysis)
                            .font(.system(size: 15))
                            .foregroundStyle(GlassTheme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Analyze this frame privately on your iPhone — describe who or what is in view.")
                            .font(.system(size: 13))
                            .foregroundStyle(GlassTheme.secondary)
                        Button {
                            Task { await analyzeOnDevice() }
                        } label: {
                            HStack(spacing: 6) {
                                if isAnalyzingOnDevice {
                                    ProgressView().tint(.white).scaleEffect(0.7)
                                }
                                Text(isAnalyzingOnDevice ? "Analyzing…" : "Analyze on device")
                            }
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                        .disabled(isAnalyzingOnDevice)
                    }
                }
            }
        }
    }

    /// Pull the already-loaded snapshot from the image cache and run on-device scene description.
    @available(iOS 27.0, *)
    private func analyzeOnDevice() async {
        guard !isAnalyzingOnDevice,
              let url = appState.client?.eventSnapshotURL(id: event.id),
              let cgImage = ImageCache.shared.image(for: url)?.cgImage else {
            withAnimation { onDeviceAnalysis = "Snapshot isn't ready yet — open the snapshot first, then try again." }
            return
        }
        Haptics.tap()
        isAnalyzingOnDevice = true
        defer { isAnalyzingOnDevice = false }
        // Scene description + any legible text (license plates, package labels) — both on-device.
        async let scene = AppleAI.describeScene(in: cgImage, cameraName: event.camera)
        async let text = AppleAI.readText(in: cgImage)
        let (description, legibleText) = await (scene, text)
        var combined = description ?? "Couldn't analyze this frame on-device."
        if let legibleText, !legibleText.isEmpty {
            combined += "\n\n📄 Text seen: \(legibleText)"
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            onDeviceAnalysis = combined
        }
    }

    private func aiCard(_ text: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                    Text("AI Description")
                        .font(.headline)
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    Button {
                        Haptics.tap()
                        editedAIDescription = text
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            isEditingAIDescription = true
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GlassTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit description")
                    Button {
                        Task { await regenerateAIDescription() }
                    } label: {
                        if isRegeneratingAI {
                            ProgressView().tint(GlassTheme.accent).scaleEffect(0.75)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(GlassTheme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRegeneratingAI)
                    .accessibilityLabel("Regenerate description")
                }
                if isEditingAIDescription {
                    TextEditor(text: $editedAIDescription)
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.primary)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(GlassTheme.Space.s)
                        .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
                    HStack(spacing: GlassTheme.Space.m) {
                        Button("Cancel") {
                            Haptics.tap()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isEditingAIDescription = false
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(GlassTheme.secondary)
                        Spacer()
                        Button("Save") {
                            Task { await saveAIDescription() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                        .disabled(isSavingAI)
                    }
                } else {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Skeleton shown while the GenAI description is being fetched, so the card keeps its
    /// shape instead of popping in only once text arrives.
    private var aiSkeletonCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                    Text("AI Description")
                        .font(.headline)
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                }
                SkeletonBlock().frame(height: 13).frame(maxWidth: .infinity, alignment: .leading)
                SkeletonBlock().frame(height: 13).frame(maxWidth: .infinity, alignment: .leading)
                SkeletonBlock().frame(width: 180, height: 13)
            }
        }
        .accessibilityLabel("Loading AI description")
    }

    private var heroCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                Picker("Media", selection: $mediaMode) {
                    ForEach(MediaMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mediaMode) { _, mode in
                    Haptics.select()
                    if mode == .video { clipModel.play() } else { clipModel.pause() }
                }

                ZStack {
                    if hasClip, mediaMode == .video {
                        // Holds a loading skeleton until a real frame is ready, then fades the
                        // clip in — never a black box.
                        LoadingClipPlayer(model: clipModel)
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
                    } else if let url = appState.client?.latestFrameURL(camera: event.camera) {
                        // No event snapshot — show the camera's latest frame, never a black box.
                        RemoteImage(url: url, contentMode: .fit)
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                    } else {
                        Color.black
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                    }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
                .expandableMedia(fullscreenMedia)

                HStack(alignment: .top, spacing: GlassTheme.Space.m) {
                    VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                        Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(GlassTheme.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("\(titleize(event.camera)) · \(timestamp(event.startTime))")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(GlassTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if hasClip {
                        Button {
                            Task { await shareClip() }
                        } label: {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(GlassTheme.accent)
                                .symbolEffect(.pulse, isActive: isPreparingShare)
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparingShare)
                        .accessibilityLabel(isPreparingShare ? "Preparing clip to share" : "Share clip")

                        Button {
                            Task { await downloadClip() }
                        } label: {
                            Image(systemName: isDownloading ? "arrow.down.circle" : "arrow.down.circle.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(GlassTheme.accent)
                                .symbolEffect(.pulse, isActive: isDownloading)
                        }
                        .buttonStyle(.plain)
                        .disabled(isDownloading)
                        .accessibilityLabel(isDownloading ? "Saving clip" : "Save clip to Photos")
                    }
                }

                if let downloadFeedback {
                    Text(downloadFeedback)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(GlassTheme.green)
                        .transition(.opacity)
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
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Details")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: GlassTheme.Space.s)], spacing: GlassTheme.Space.s) {
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
                        HStack(spacing: GlassTheme.Space.s) {
                            ForEach(zones, id: \.self) { zone in
                                Label(titleize(zone), systemImage: "mappin.and.ellipse")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(GlassTheme.accent)
                                    .padding(.horizontal, GlassTheme.Space.m)
                                    .padding(.vertical, GlassTheme.Space.s)
                                    .background(GlassTheme.accent.opacity(0.12), in: Capsule())
                                    .accessibilityLabel("Zone \(titleize(zone))")
                            }
                        }
                    }
                }
            }
        }
    }

    private func downloadClip() async {
        guard let client = appState.client else { return }
        Haptics.tap()
        isDownloading = true
        downloadFeedback = nil
        defer { isDownloading = false }
        do {
            let url = client.eventClipURL(id: event.id)
            try await ClipDownloader.downloadToPhotos(url: url, client: client, fileName: "Apex-\(event.id)")
            Haptics.success()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                downloadFeedback = "Saved to Photos."
            }
        } catch {
            Haptics.error()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                downloadFeedback = error.localizedDescription
            }
        }
    }

    private var actionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Actions")

                if let feedback = actionFeedback {
                    Text(feedback)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(actionIsError ? GlassTheme.red : GlassTheme.green)
                        .transition(.opacity.combined(with: .move(edge: .top)))
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
                        HStack(spacing: GlassTheme.Space.m) {
                            Image(systemName: "video.fill")
                                .font(.subheadline.weight(.semibold))
                            Text("Open Live Camera")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(GlassTheme.tertiary)
                        }
                        .foregroundStyle(GlassTheme.accent)
                        .padding(.horizontal, GlassTheme.Space.l)
                        .padding(.vertical, GlassTheme.Space.m)
                        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                        .cardStroke(GlassTheme.Radius.tile)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, tint: Color, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: GlassTheme.Space.m) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                Spacer()
                if isLoading {
                    ProgressView().tint(tint)
                }
            }
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.vertical, GlassTheme.Space.m)
            .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            .cardStroke(GlassTheme.Radius.tile)
        }
        .buttonStyle(.plain)
        // Per-action: only this button disables while it's working, not the whole list.
        .disabled(isLoading)
    }

    /// Shows a transient feedback line (auto-clears) in the Actions card.
    private func showFeedback(_ message: String, isError: Bool) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            actionFeedback = message
            actionIsError = isError
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if actionFeedback == message {
                withAnimation(.easeOut(duration: 0.2)) { actionFeedback = nil }
            }
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
        guard !isSavingAI else { return }
        isSavingAI = true
        defer { isSavingAI = false }
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
            Haptics.error()
        }
        showSimilarSheet = true
    }

    private var confidence: String {
        guard let score = event.score ?? event.topScore else { return "n/a" }
        return "\(Int(score * 100))%"
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GlassTheme.tertiary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GlassTheme.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GlassTheme.Space.m)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
        .cardStroke(GlassTheme.Radius.tile)
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
