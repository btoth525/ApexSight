import SwiftUI
import AVKit
import AVFoundation

struct EventDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let event: FrigateEvent
    @State private var actionFeedback: String?
    @State private var actionIsError = false
    @State private var isActing = false
    @StateObject private var clipModel = ClipPlayerModel()
    @State private var downloadFeedback: String?
    @State private var isPreparingShare = false
    @State private var sharePayload: SharePayload?
    @State private var mediaMode: MediaMode = .video
    /// True while our fullscreen media cover is presented — onDisappear must NOT stop the
    /// clip player then (the cover is displaying that very player).
    @State private var mediaExpanded = false
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
            // A real clip is showing — expand opens the zoomable video. Gate on isReady
            // (the AVPlayer exists synchronously from the first load call, so `player != nil`
            // was true during buffering and tapping the skeleton opened a black viewer).
            guard clipModel.isReady, let player = clipModel.player else { return nil }
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
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
        .onAppear {
            #if DEBUG
            // Sim-driving hook: synthetic taps can't switch a segmented Picker, so tests inject
            // the media tab via the app group (0=video 1=snapshot 2=history).
            let modes: [MediaMode] = [.video, .snapshot, .history]
            if let raw = UserDefaults(suiteName: ApexAppGroup.identifier)?.object(forKey: "apex.debug.mediaMode") as? Int,
               modes.indices.contains(raw) {
                mediaMode = modes[raw]
            }
            #endif
        }
        .task(id: event.id) {
            // Clear the prior event's text first — otherwise, when this view is reused for a new
            // event (NavigationLink to another FrigateEvent), event A's description lingers over
            // event B until B's fetch returns.
            genAIDescription = nil
            isLoadingAIDescription = true
            let fetched = try? await appState.client?.eventDescription(id: event.id)
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
                genAIDescription = fetched
                isLoadingAIDescription = false
            }
        }
        .task(id: event.id) {
            // On-device analysis: show the saved result instantly, or run it once automatically —
            // but only for cameras the user enabled in Settings → Apple Intelligence → AI Cameras.
            if #available(iOS 27.0, *), AppleAI.visionAIAvailable, AICameraSettings.isEnabled(event.camera) {
                onDeviceAnalysis = nil
                await loadOrRunAnalysis()
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
        if #available(iOS 27.0, *), AppleAI.visionAIAvailable, AICameraSettings.isEnabled(event.camera) {
            GlassCard {
                VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                    HStack(spacing: GlassTheme.Space.s) {
                        Image(systemName: "apple.intelligence")
                            .foregroundStyle(GlassTheme.accent)
                        SectionHeader("On-Device Analysis")
                        Spacer()
                    }
                    if isAnalyzingOnDevice && onDeviceAnalysis == nil {
                        HStack(spacing: GlassTheme.Space.s) {
                            ProgressView().tint(.white).scaleEffect(0.7)
                            Text("Analyzing on your iPhone…")
                                .font(.system(size: 13))
                                .foregroundStyle(GlassTheme.secondary)
                        }
                    } else if let onDeviceAnalysis {
                        Text(onDeviceAnalysis)
                            .font(.system(size: 15))
                            .foregroundStyle(GlassTheme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await analyzeOnDevice(force: true) }
                        } label: {
                            Label("Re-analyze", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(GlassTheme.accent)
                        .disabled(isAnalyzingOnDevice)
                    } else {
                        Text("Couldn't analyze this frame.")
                            .font(.system(size: 13))
                            .foregroundStyle(GlassTheme.secondary)
                        Button { Task { await analyzeOnDevice(force: true) } } label: {
                            Text("Try again")
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                        .disabled(isAnalyzingOnDevice)
                    }
                }
            }
        }
    }

    /// Load a saved analysis for this event, or run one automatically the first time it's opened —
    /// so the user never has to press a button and the result survives closing the app.
    @available(iOS 27.0, *)
    private func loadOrRunAnalysis() async {
        if let cached = AIAnalysisStore.load(event.id) {
            onDeviceAnalysis = cached
            return
        }
        await analyzeOnDevice(force: false)
    }

    /// Fetch the event snapshot FRESH (the image cache is only warmed on the Snapshot tab, so an
    /// event showing its clip has no cached frame — that's why analysis used to say "waiting for
    /// snapshot"), run scene description + text OCR on-device, show it, and persist it.
    @available(iOS 27.0, *)
    private func analyzeOnDevice(force: Bool) async {
        guard !isAnalyzingOnDevice, let client = appState.client else { return }
        if force { Haptics.tap() }
        isAnalyzingOnDevice = true
        // On an explicit re-run, clear the old text so the "Analyzing…" spinner shows.
        if force { withAnimation { onDeviceAnalysis = nil } }
        defer { isAnalyzingOnDevice = false }

        var combined: String?

        // Prefer the animated preview GIF — a short sequence lets the AI read MOTION ("walked up,
        // left a package, drove off"), which is far better than a single still. Falls back to the
        // snapshot when there's no clip or too few frames.
        if hasClip,
           let gifData = try? await client.imageData(from: client.eventPreviewGifURL(id: event.id)) {
            combined = await AppleAI.describeEvent(gifData: gifData, cameraName: event.camera, knownLabel: event.label)
        }

        if combined == nil,
           let data = try? await client.imageData(from: client.eventSnapshotURL(id: event.id)),
           let cgImage = UIImage(data: data)?.cgImage {
            async let scene = AppleAI.describeScene(in: cgImage, cameraName: event.camera, knownLabel: event.label)
            async let text = AppleAI.readText(in: cgImage)
            let (description, legibleText) = await (scene, text)
            if let description {
                var single = description
                if let legibleText, !legibleText.isEmpty { single += "\n\n📄 Text seen: \(legibleText)" }
                combined = single
            }
        }

        guard let result = combined else {
            if force { withAnimation { onDeviceAnalysis = nil } }
            return
        }
        AIAnalysisStore.save(event.id, result)
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
            onDeviceAnalysis = result
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
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                            isEditingAIDescription = true
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GlassTheme.accent)
                            .hitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit description")
                    Button {
                        Task { await regenerateAIDescription() }
                    } label: {
                        Group {
                            if isRegeneratingAI {
                                ProgressView().tint(GlassTheme.accent).scaleEffect(0.75)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(GlassTheme.accent)
                            }
                        }
                        .hitTarget()
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
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
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
                        // Plain image inline (no inner scroll-zoom) so a tap flows through to
                        // `.expandableMedia`, which opens the full-screen zoomable viewer.
                        RemoteImage(url: url, contentMode: .fit)
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
                .expandableMedia(fullscreenMedia, isPresented: $mediaExpanded)

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
                            .lineLimit(2)
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
                                .hitTarget()
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparingShare)
                        .accessibilityLabel(isPreparingShare ? "Preparing clip to share" : "Share clip")
                        // (Save-to-Photos button removed — it errored on the Photos write; Share
                        // covers saving via the share sheet's "Save Video", which works reliably.)
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
                // loadIfNeeded is URL-keyed: a reused view for a NEW event loads fresh, but a
                // re-appear for the SAME event (returning from fullscreen expand or a push)
                // keeps the existing playback instead of reloading + ghost-auto-playing.
                clipModel.loadIfNeeded(client: client, url: client.eventVodURL(id: event.id))
            }
            .onDisappear { if !mediaExpanded { clipModel.stop() } }
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


    private var actionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Actions")

                if let feedback = actionFeedback {
                    Text(feedback)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(actionIsError ? GlassTheme.red : GlassTheme.green)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
            actionFeedback = message
            actionIsError = isError
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if actionFeedback == message {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { actionFeedback = nil }
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
