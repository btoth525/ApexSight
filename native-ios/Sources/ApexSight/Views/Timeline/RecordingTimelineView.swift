import AVFoundation
import SwiftUI

/// The camera's recording timeline: video on top, a scrolling ruler under a fixed playhead,
/// transport controls in the thumb zone, and day chips to jump across days.
///
/// The interaction model is the one the best NVR apps converge on: **drag the ruler and the
/// footage scrubs under your finger** (a locally-seeked preview video, so it is instant and
/// costs the server nothing), lift and it plays from there, pinch to change how much time is on
/// screen, and every crossed detection ticks. Playback follows the playhead; the playhead follows
/// playback. Nothing here scrolls vertically — the whole screen is the instrument.
///
/// Footage loads one HOUR at a time (`recordingHLSURL`), and any scrub inside the loaded hour is a
/// pure local seek. That is what makes repeat scrubbing feel like a local file; only crossing an
/// hour boundary asks Frigate for a new manifest (~60 ms via nginx-vod).
struct RecordingTimelineView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine: TimelineEngine
    @StateObject private var clipModel = ClipPlayerModel()

    init(camera: FrigateCamera) {
        self.camera = camera
        _engine = State(initialValue: TimelineEngine(center: Date().timeIntervalSince1970 - 15))
    }

    /// Everything the ruler needs for one local day, fetched together and kept so crossing back
    /// over a day boundary never re-asks.
    private struct DayData {
        var events: [FrigateEvent] = []
        var motion: [FrigateClient.MotionSample] = []
        var coverage: [ClosedRange<Double>] = []
        var segments: [FrigateClient.PreviewSegment] = []
        var frames: [FrigateClient.PreviewFrame] = []
    }

    /// The loaded days flattened, filtered and sorted ONCE per data change (`remerge()`), instead of
    /// on every body pass. These used to be computed properties — `flatMap` + `sorted` over every
    /// motion sample and event of two or three days, plus a category tally — re-evaluated on each
    /// scrub tick. Now a day landing or a filter chip flipping rebuilds them; a drag reads them.
    private struct MergedDays {
        var events: [FrigateEvent] = []
        /// `events` minus the categories the user switched off.
        var visibleEvents: [FrigateEvent] = []
        /// Newest first — the Moments strip order.
        var momentItems: [FrigateEvent] = []
        var categoryCounts: [TimelineStyle.Category: Int] = [:]
        var motion: [FrigateClient.MotionSample] = []
        var coverage: [ClosedRange<Double>] = []
        var segments: [FrigateClient.PreviewSegment] = []
        var frames: [FrigateClient.PreviewFrame] = []
    }
    @State private var merged = MergedDays()

    /// Object categories the user has switched off — hidden from the ruler, the Moments strip and
    /// prev/next, so "just show me people" is one tap. Empty = everything.
    @State private var hiddenCategories: Set<TimelineStyle.Category> = []
    /// How much time was across the screen last time — the zoom is a preference, not a per-visit
    /// choice, so it comes back the way it was left.
    @AppStorage("apex.timelineVisibleSeconds") private var storedVisibleSeconds: Double = 3600

    @State private var days: [Double: DayData] = [:]
    @State private var loadingDays: Set<Double> = []
    /// Days that have any recording, newest first — from `recordings/summary`. Today is always
    /// offered even before it has a summary row.
    @State private var summaryDays: [Date] = []
    @State private var dayCounts: [Double: Int] = [:]
    @State private var loadError: String?

    /// The moment card to scroll into view after a deliberate jump (never during follow, so the
    /// strip doesn't crawl away from under a browsing finger).
    @State private var momentFocusID: String?
    /// Local day the follow loop last made sure was loaded.
    @State private var followedDay: Double = 0
    /// The moment the player still has to land on. Set by every jump, cleared only when AVPlayer
    /// confirms the seek completed. While it is set the follow loop stays quiet, because the
    /// player's clock still reports the OLD position — and an HLS item seeked before its playlist
    /// has parsed clamps to the start, which is exactly how "tap a moment" turned into "play the
    /// top of the hour".
    @State private var pendingSeek: Double?

    // Playback
    /// Epoch range of the hour manifest currently in `clipModel` — a seek inside it is local.
    @State private var loadedWindow: ClosedRange<Double>?
    @State private var isPlaying = true
    @State private var speed: Float = 1
    private static let speeds: [Float] = [1, 2, 4]

    // Scrub preview — a second, muted player holding the hour's packed preview video (640×180
    // timelapse, disk-cached, immutable). It seeks locally while the finger drags, so the
    // picture moves with zero network. Inherited from the previous browser; it was its best idea.
    @State private var previewPlayer: AVPlayer?
    @State private var loadedSegment: FrigateClient.PreviewSegment?
    @State private var previewVideoTask: Task<Void, Never>?

    // Share / save
    @State private var isPreparingShare = false
    @State private var isDownloading = false
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var sharePayload: SharePayload?

    private let calendar = Calendar.current
    private let clipSeconds: Double = 300
    /// Frigate hasn't necessarily flushed the last few seconds to its recordings DB; asking for
    /// them 404s as if there were no footage at all. Every playback request stays behind this.
    private let liveMargin: Double = 15

    // MARK: - Body

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 0) {
                videoSurface
                TimelineReadout(engine: engine, isPlaying: isPlaying, goLive: goLive)
                    .padding(.horizontal, GlassTheme.Space.l)
                    .padding(.top, GlassTheme.Space.m)
                transport
                    .padding(.vertical, GlassTheme.Space.s)
                TimelineRuler(engine: engine, events: merged.visibleEvents, motion: merged.motion, coverage: merged.coverage,
                              onScrubEnd: { time in scrubEnded(at: time) },
                              onTapEvent: { event in jump(to: event) })
                    .frame(height: 132)
                // Everything under the ruler scrolls, so no phone — and no tab bar — can ever push
                // the Moments strip off the bottom where its taps stop landing.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        categoryFilters
                            .padding(.vertical, GlassTheme.Space.s)
                        DayChipsRow(days: summaryDays, counts: dayCounts, engine: engine) { day in
                            Task { await select(day: day) }
                        }
                        .padding(.bottom, GlassTheme.Space.s)
                        MomentsStrip(items: merged.momentItems, engine: engine, focusID: momentFocusID,
                                     thumbURL: { id in appState.client?.eventThumbnailURL(id: id) },
                                     jump: { event in jump(to: event) })
                            .padding(.top, GlassTheme.Space.xs)
                        if let loadError { errorLine(loadError) }
                        if let feedback { feedbackLine(feedback) }
                    }
                    .padding(.bottom, GlassTheme.Space.l)
                }
            }
        }
        .navigationTitle(titleize(camera.name))
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        // An instrument, not a page: the tab bar would sit on top of the transport row.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actionsMenu }
        }
        .task { await bootstrap() }
        .task { await followPlayback() }
        // The zoom is persisted when the pinch ENDS. Reading `engine.visibleSeconds` in body would
        // subscribe this whole view to every pinch tick; `isInteracting` flips twice per gesture.
        .onChange(of: engine.isInteracting) { _, interacting in
            if !interacting { storedVisibleSeconds = engine.visibleSeconds }
        }
        .onChange(of: hiddenCategories) { _, _ in remerge() }
        .onChange(of: clipModel.isReady) { _, ready in
            if ready { performPendingSeek() }
        }
        .onChange(of: clipModel.reachedEndCount) { _, _ in hourEnded() }
        .onDisappear(perform: teardown)
        .sheet(item: $sharePayload) { payload in ShareSheet(items: payload.items) }
    }

    // MARK: - Video

    /// The camera's true aspect, kept between 4:3 and 16:9 so an ultra-wide feed letterboxes
    /// inside a usable frame rather than shrinking the whole screen's video to a strip.
    private var videoAspect: CGFloat { min(16.0 / 9.0, max(4.0 / 3.0, camera.aspectRatio)) }

    private var videoSurface: some View {
        ZStack {
            LoadingClipPlayer(model: clipModel)
            if engine.isInteracting {
                ScrubOverlay(engine: engine, previewPlayer: previewPlayer, loadedSegment: loadedSegment,
                             nearestStill: nearestStillURL(at:), onCenterChanged: syncPreviewPlayer)
            }
        }
        .aspectRatio(videoAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: engine.isInteracting)
        .expandableMedia(clipModel.player.map { FullscreenMediaView.Media.player($0) })
    }

    private var transport: some View {
        HStack(spacing: 0) {
            transportButton("backward.end.fill", label: "Previous detection") { jumpToEvent(direction: -1) }
            transportButton("gobackward.10", label: "Back 10 seconds") { skip(-10) }
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 58, height: 58)
                    .background(GlassTheme.accent, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .frame(maxWidth: .infinity)
            transportButton("goforward.10", label: "Forward 10 seconds") { skip(10) }
            transportButton("forward.end.fill", label: "Next detection") { jumpToEvent(direction: 1) }
            speedButton
        }
        .padding(.horizontal, GlassTheme.Space.s)
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(GlassTheme.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .frame(maxWidth: .infinity)
    }

    private var speedButton: some View {
        Button {
            Haptics.select()
            let idx = Self.speeds.firstIndex(of: speed) ?? 0
            speed = Self.speeds[(idx + 1) % Self.speeds.count]
            applyRate()
        } label: {
            Text("\(Int(speed))×")
                .font(.footnote.weight(.black))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(speed == 1 ? GlassTheme.secondary : .black)
                .frame(width: 40, height: 30)
                .background {
                    if speed == 1 {
                        Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1)
                    } else {
                        Capsule().fill(GlassTheme.accent)
                    }
                }
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed \(Int(speed)) times")
        .frame(maxWidth: .infinity)
    }

    // MARK: - Object filters

    /// One row that is both the legend and the filter: each chip is a category present on the
    /// loaded days, with its colour and count. Tap to hide it everywhere; tap again to bring it back.
    private var categoryFilters: some View {
        let counts = merged.categoryCounts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GlassTheme.Space.s) {
                ForEach(TimelineStyle.Category.allCases) { category in
                    if let count = counts[category], count > 0 {
                        filterChip(category, count: count)
                    }
                }
            }
            .padding(.horizontal, GlassTheme.Space.l)
        }
    }

    private func filterChip(_ category: TimelineStyle.Category, count: Int) -> some View {
        let hidden = hiddenCategories.contains(category)
        return Button {
            Haptics.select()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                if hidden { hiddenCategories.remove(category) } else { hiddenCategories.insert(category) }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(hidden ? GlassTheme.tertiary : category.color)
                    .frame(width: 8, height: 8)
                Text(category.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(hidden ? GlassTheme.tertiary : GlassTheme.primary)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(hidden ? GlassTheme.tertiary : GlassTheme.secondary)
            }
            .padding(.horizontal, GlassTheme.Space.m)
            .frame(height: 32)
            .background {
                Capsule().fill(hidden ? Color.clear : GlassTheme.surface)
                Capsule().strokeBorder(hidden ? GlassTheme.separator : category.color.opacity(0.45), lineWidth: 1)
            }
            .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.title), \(count)")
        .accessibilityValue(hidden ? "Hidden" : "Shown")
        .accessibilityHint("Double tap to \(hidden ? "show" : "hide") on the timeline")
    }

    // MARK: - Menu + messages

    private var actionsMenu: some View {
        Menu {
            Button { Task { await shareCurrent() } } label: {
                Label(isPreparingShare ? "Preparing…" : "Share 5-minute clip", systemImage: "square.and.arrow.up")
            }
            .disabled(isPreparingShare || loadedWindow == nil)
            Button { Task { await saveCurrent() } } label: {
                Label(isDownloading ? "Saving…" : "Save 5 minutes to Photos", systemImage: "arrow.down.circle")
            }
            .disabled(isDownloading || loadedWindow == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More actions")
    }

    private func errorLine(_ message: String) -> some View {
        HStack(spacing: GlassTheme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GlassTheme.orange)
            Text(message).font(.footnote.weight(.medium)).foregroundStyle(GlassTheme.secondary)
            Spacer()
            Button("Retry") {
                loadError = nil
                Task { await bootstrap() }
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(GlassTheme.accent)
            .hitTarget()
        }
        .padding(.horizontal, GlassTheme.Space.l)
        .padding(.top, GlassTheme.Space.s)
    }

    private func feedbackLine(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(feedbackIsError ? GlassTheme.red : GlassTheme.green)
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.top, GlassTheme.Space.s)
            .transition(.opacity)
    }

    // MARK: - Merged data

    private var allEvents: [FrigateEvent] { merged.events }
    private var visibleEvents: [FrigateEvent] { merged.visibleEvents }
    private var allSegments: [FrigateClient.PreviewSegment] { merged.segments }
    private var allFrames: [FrigateClient.PreviewFrame] { merged.frames }

    /// Rebuilds `merged` from `days` + `hiddenCategories`. Called when a day lands and when a filter
    /// chip flips — the only two things that change the answer.
    private func remerge() {
        var m = MergedDays()
        m.events = days.values.flatMap(\.events)
        m.motion = days.values.flatMap(\.motion).sorted { $0.startTime < $1.startTime }
        m.coverage = days.values.flatMap(\.coverage)
        m.segments = days.values.flatMap(\.segments)
        m.frames = days.values.flatMap(\.frames)
        m.visibleEvents = hiddenCategories.isEmpty
            ? m.events
            : m.events.filter { !hiddenCategories.contains(TimelineStyle.category(for: $0.label)) }
        m.momentItems = m.visibleEvents
            .filter { $0.startTime != nil }
            .sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
        m.categoryCounts = Dictionary(grouping: m.events, by: { TimelineStyle.category(for: $0.label) })
            .mapValues(\.count)
        merged = m
    }

    private func dayStart(_ t: Double) -> Double {
        calendar.startOfDay(for: Date(timeIntervalSince1970: t)).timeIntervalSince1970
    }

    // MARK: - Loading

    private func bootstrap() async {
        guard let client = appState.client else { return }
        clipModel.loopsAtEnd = false
        clipModel.preferredForwardBufferDuration = 8   // hour-long VOD at up to 4×, often over the tunnel
        engine.zoom(to: storedVisibleSeconds)
        let now = Date().timeIntervalSince1970
        let today = calendar.startOfDay(for: Date())

        // Which days exist, for the chips. Today is always offered.
        let summary = await client.recordingSummary(camera: camera.name)
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        var found: [Date: Int] = [today: 0]
        for row in summary {
            guard let d = parser.date(from: row.day) else { continue }
            found[calendar.startOfDay(for: d), default: 0] += row.events
        }
        summaryDays = found.keys.sorted(by: >)
        dayCounts = Dictionary(uniqueKeysWithValues: found.map { ($0.key.timeIntervalSince1970, $0.value) })
        engine.earliest = summaryDays.last?.timeIntervalSince1970

        await loadDay(today.timeIntervalSince1970)

        // Land on the last thing that happened today — the reason someone opens a timeline —
        // or a moment ago if the day has been quiet.
        let landing = days[today.timeIntervalSince1970]?.events.compactMap(\.startTime).max()
            .map { max($0 - 2, today.timeIntervalSince1970) } ?? (now - liveMargin)
        engine.center = landing
        playFrom(time: landing)
    }

    private func loadDay(_ start: Double) async {
        guard days[start] == nil, !loadingDays.contains(start), let client = appState.client else { return }
        loadingDays.insert(start)
        defer { loadingDays.remove(start) }
        let end = min(start + 86400, Date().timeIntervalSince1970 + 60)
        let startDate = Date(timeIntervalSince1970: start), endDate = Date(timeIntervalSince1970: end)

        async let events = try? client.events(camera: camera.name, after: startDate, before: endDate, limit: 500)
        async let motion = client.motionActivity(camera: camera.name, after: start, before: end)
        async let recordings = try? client.recordings(camera: camera.name, after: startDate, end: endDate)
        async let segments = client.previewSegments(camera: camera.name, start: start, end: end)
        async let frames = client.previewFrames(camera: camera.name, start: start, end: end)

        let loadedEvents = await events
        let loadedRecordings = await recordings
        if loadedEvents == nil && loadedRecordings == nil {
            loadError = "Couldn't reach Frigate for that day."
            return   // deliberately NOT cached: a retry or the next scroll into this day asks again
        }
        days[start] = DayData(events: loadedEvents ?? [],
                              motion: await motion,
                              coverage: Self.mergeCoverage(loadedRecordings ?? []),
                              segments: await segments,
                              frames: await frames)
        remerge()
    }

    /// Frigate lists ~10-second segments — thousands per day. Merged into continuous ranges so the
    /// ruler draws a handful of strips, and so a real gap in coverage is visible as a real gap.
    private static func mergeCoverage(_ recordings: [FrigateRecording]) -> [ClosedRange<Double>] {
        let sorted = recordings.compactMap { r -> (Double, Double)? in
            guard let s = r.startTime, let e = r.endTime, e > s else { return nil }
            return (s, e)
        }.sorted { $0.0 < $1.0 }
        var merged: [ClosedRange<Double>] = []
        for (s, e) in sorted {
            if let last = merged.last, s <= last.upperBound + 2 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, e)
            } else {
                merged.append(s...e)
            }
        }
        return merged
    }

    /// Makes sure the day under `t` (and its neighbour when near midnight) is loaded, so a scrub
    /// or playback across a boundary never lands on an empty ruler.
    private func ensureLoaded(around t: Double) {
        let day = dayStart(t)
        var wanted: Set<Double> = [day]
        if t - day < 2 * 3600 { wanted.insert(day - 86400) }
        if day + 86400 - t < 2 * 3600 { wanted.insert(day + 86400) }
        for d in wanted where d <= Date().timeIntervalSince1970 {
            Task { await loadDay(d) }
        }
    }

    // MARK: - Playback

    private func scrubEnded(at time: Double) {
        ensureLoaded(around: time)
        playFrom(time: time)
    }

    private func jump(to event: FrigateEvent) {
        guard let start = event.startTime else { return }
        momentFocusID = event.id
        zoomInForEvent()
        playFrom(time: start - 2)
    }

    /// Landing on a detection from a wide zoom leaves it as a sliver on a 24-hour ruler; pull in to
    /// half an hour so the moment and what surrounds it are readable. Never zooms OUT.
    private func zoomInForEvent() {
        guard engine.visibleSeconds > 1800 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { _ = engine.zoom(to: 1800) }
    }

    private func jumpToEvent(direction: Int) {
        let starts = visibleEvents.compactMap(\.startTime).sorted()
        let c = engine.center
        let target = direction > 0 ? starts.first { $0 > c + 1 } : starts.last { $0 < c - 1 }
        guard let target else { Haptics.warning(); return }
        Haptics.tap()
        momentFocusID = visibleEvents.first { $0.startTime == target }?.id
        zoomInForEvent()
        playFrom(time: target - 2)
    }

    private func skip(_ seconds: Double) {
        Haptics.tap()
        playFrom(time: engine.center + seconds)
    }

    private func togglePlay() {
        isPlaying.toggle()
        Haptics.press()
        applyRate()
    }

    private func goLive() {
        guard !engine.isLive(playing: isPlaying) else { return }
        Haptics.press()
        isPlaying = true
        playFrom(time: engine.latest - liveMargin)
    }

    private func applyRate() {
        clipModel.player?.rate = isPlaying ? speed : 0
    }

    /// Seeks to (or loads) the footage for a moment. Inside the loaded hour → instant local seek;
    /// otherwise the whole hour's manifest is fetched once so every further scrub in it is local.
    private func playFrom(time rawTime: Double) {
        guard let client = appState.client else { return }
        let time = engine.clamped(min(rawTime, Date().timeIntervalSince1970 - liveMargin))
        engine.center = time
        engine.playingTime = time
        feedback = nil

        if let window = loadedWindow, window.contains(time),
           clipModel.player != nil, !clipModel.hasError {
            seekWhenReady(to: time)
            return
        }
        let hourStart = floor(time / 3600) * 3600
        let hourEnd = min(hourStart + 3600, Date().timeIntervalSince1970 - 5)
        loadedWindow = hourStart...hourEnd
        // Hold playback until the jump has landed; otherwise AVPlayer starts at the top of the
        // hour the instant the playlist parses and the seek arrives a beat later.
        clipModel.player?.rate = 0
        clipModel.load(client: client, url: client.recordingHLSURL(camera: camera.name, start: hourStart, end: hourEnd))
        seekWhenReady(to: time)
    }

    /// Land on `time` once the item can actually seek there. If it's ready now the seek goes
    /// immediately; if not, `.onChange(of: clipModel.isReady)` finishes the job.
    private func seekWhenReady(to time: Double) {
        pendingSeek = time
        guard clipModel.isReady else { return }
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard let target = pendingSeek, let window = loadedWindow else { return }
        clipModel.seek(toOffset: target - window.lowerBound) { finished in
            Task { @MainActor in
                // A newer jump superseded this one; its own completion owns the state now.
                guard pendingSeek == target else { return }
                pendingSeek = nil
                if finished { applyRate() } else { performPendingSeek() }
            }
        }
    }

    /// Keeps the playhead on the picture: while playing, the ruler follows the player; when the
    /// loaded hour runs out, the next one is loaded so a long watch never just stops.
    private func followPlayback() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !engine.isInteracting, isPlaying, pendingSeek == nil,
                  let window = loadedWindow, let player = clipModel.player, clipModel.isReady else { continue }
            let t = player.currentTime().seconds
            guard t.isFinite, t >= 0 else { continue }
            let absolute = window.lowerBound + t
            engine.center = absolute
            engine.playingTime = absolute
            let day = dayStart(absolute)
            if day != followedDay {
                followedDay = day
                ensureLoaded(around: absolute)
            }
        }
    }

    /// The loaded hour played out. Continue into the next hour — unless this WAS the live hour,
    /// in which case there is nothing newer yet: hold on the last frame with the LIVE pill lit,
    /// and a tap on it re-fetches. (Reloading the same hour every few seconds to chase the edge
    /// flickers the player; a real live view is the Cameras tab's job.)
    private func hourEnded() {
        guard let window = loadedWindow else { return }
        if window.upperBound < engine.latest - 60 {
            playFrom(time: window.upperBound + 1)
        }
    }

    private func select(day: Date) async {
        Haptics.select()
        let start = day.timeIntervalSince1970
        await loadDay(start)
        let landing: Double
        if let last = days[start]?.events.compactMap(\.startTime).max() {
            landing = max(last - 2, start)
        } else if calendar.isDateInToday(day) {
            landing = Date().timeIntervalSince1970 - liveMargin
        } else {
            landing = start + 12 * 3600
        }
        isPlaying = true
        playFrom(time: landing)
    }

    // MARK: - Scrub preview

    private func nearestStillURL(at t: Double) -> URL? {
        guard let client = appState.client else { return nil }
        if let frame = allFrames.min(by: { abs($0.time - t) < abs($1.time - t) }), abs(frame.time - t) <= 90 {
            return client.previewFrameURL(filename: frame.filename)
        }
        let candidate = allEvents
            .compactMap { e -> (FrigateEvent, Double)? in
                guard let s = e.startTime else { return nil }
                return (e, abs(s - t))
            }
            .min { $0.1 < $1.1 }
        guard let (event, delta) = candidate, delta <= 300 else { return nil }
        return client.eventThumbnailURL(id: event.id)
    }

    /// Seek the loaded hour's timelapse to the finger (proportional mapping into the file's own
    /// timebase); when the finger crosses into an hour that isn't loaded, swap videos.
    private func syncPreviewPlayer() {
        let t = engine.center
        if let seg = loadedSegment, t >= seg.start, t <= seg.end {
            guard let player = previewPlayer, let item = player.currentItem,
                  item.duration.isNumeric, item.duration.seconds > 0 else { return }
            let fraction = (t - seg.start) / max(1, seg.end - seg.start)
            player.seek(to: CMTime(seconds: item.duration.seconds * fraction, preferredTimescale: 600),
                        toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
            return
        }
        guard let seg = allSegments.first(where: { t >= $0.start && t <= $0.end }), seg != loadedSegment else { return }
        loadPreviewVideo(seg)
    }

    private func loadPreviewVideo(_ segment: FrigateClient.PreviewSegment) {
        guard let client = appState.client else { return }
        previewVideoTask?.cancel()
        previewVideoTask = Task {
            guard let local = await client.cachedPreviewVideo(for: segment),
                  !Task.isCancelled, segment.camera == camera.name else { return }
            let player = AVPlayer(url: local)
            player.isMuted = true
            player.actionAtItemEnd = .pause
            previewPlayer = player
            loadedSegment = segment
            syncPreviewPlayer()
        }
    }

    // MARK: - Share / save

    private func shareCurrent() async {
        guard let client = appState.client, let start = engine.playingTime else { return }
        Haptics.tap()
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await ClipDownloader.downloadToTempFile(
                url: client.recordingClipURL(camera: camera.name, start: start, end: start + clipSeconds),
                client: client, fileName: "Apex-\(camera.name)-\(Int(start))"
            )
            sharePayload = SharePayload(url: url)
        } catch {
            show(feedback: error.localizedDescription, isError: true)
        }
    }

    private func saveCurrent() async {
        guard let client = appState.client, let start = engine.playingTime else { return }
        Haptics.tap()
        isDownloading = true
        defer { isDownloading = false }
        do {
            let url = client.recordingClipURL(camera: camera.name, start: start, end: start + clipSeconds)
            try await ClipDownloader.downloadToPhotos(url: url, client: client, fileName: "Apex-\(camera.name)-\(Int(start))")
            show(feedback: "Saved 5 minutes to Photos.", isError: false)
        } catch {
            show(feedback: error.localizedDescription, isError: true)
        }
    }

    private func show(feedback message: String, isError: Bool) {
        feedbackIsError = isError
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { feedback = message }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                if feedback == message { feedback = nil }
            }
        }
    }

    private func teardown() {
        clipModel.stop()
        previewVideoTask?.cancel()
        previewPlayer?.pause()
        previewPlayer = nil
        loadedSegment = nil
    }
}

// MARK: - Hot-path children
//
// Each of these reads `engine.center` (or `playingTime`), the values that change at scrub and
// playback rate. Keeping those reads OUT of `RecordingTimelineView.body` is what lets a drag redraw
// just the ruler, the clock and the highlighted moment instead of the whole screen.

/// The clock under the video and the LIVE pill.
private struct TimelineReadout: View {
    let engine: TimelineEngine
    let isPlaying: Bool
    let goLive: () -> Void

    var body: some View {
        let isLive = engine.isLive(playing: isPlaying)
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date(timeIntervalSince1970: engine.center)
                        .formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GlassTheme.secondary)
                Text(Date(timeIntervalSince1970: engine.center)
                        .formatted(.dateTime.hour().minute().second()))
                    .font(.title.weight(.bold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(GlassTheme.primary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button(action: goLive) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isLive ? GlassTheme.green : GlassTheme.tertiary)
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.caption.weight(.black))
                        .foregroundStyle(isLive ? GlassTheme.green : GlassTheme.secondary)
                }
                .padding(.horizontal, GlassTheme.Space.m)
                .frame(height: 34)
                .background {
                    Capsule().fill(isLive ? GlassTheme.green.opacity(0.16) : GlassTheme.surface)
                    Capsule().strokeBorder(isLive ? GlassTheme.green.opacity(0.5) : GlassTheme.separator, lineWidth: 1)
                }
                .hitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLive ? "Live" : "Go live")
        }
        .accessibilityElement(children: .combine)
    }
}

/// While the finger is down the video surface IS the scrubber: the packed preview seeks under
/// the finger; where none is packed yet (the current hour) the nearest loose preview frame
/// stands in; failing that, the nearest detection's thumbnail.
private struct ScrubOverlay: View {
    let engine: TimelineEngine
    let previewPlayer: AVPlayer?
    let loadedSegment: FrigateClient.PreviewSegment?
    let nearestStill: (Double) -> URL?
    /// Fires on appear and on every playhead move while scrubbing — the owner seeks the preview.
    let onCenterChanged: () -> Void

    var body: some View {
        Group {
            if let previewPlayer, let seg = loadedSegment,
               engine.center >= seg.start, engine.center <= seg.end {
                PreviewPlayerLayerView(player: previewPlayer)
                    .transition(.opacity)
            } else if let url = nearestStill(engine.center) {
                RemoteImage(url: url, contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .onAppear(perform: onCenterChanged)
        .onChange(of: engine.center) { _, _ in onCenterChanged() }
    }
}

/// One chip per day that has recordings; the day under the playhead is filled.
private struct DayChipsRow: View {
    let days: [Date]
    let counts: [Double: Int]
    let engine: TimelineEngine
    let select: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        // One calendar lookup per pass, not one per chip.
        let selectedDay = calendar.startOfDay(for: Date(timeIntervalSince1970: engine.center))
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GlassTheme.Space.s) {
                ForEach(days, id: \.self) { day in chip(day, selected: day == selectedDay) }
            }
            .padding(.horizontal, GlassTheme.Space.l)
        }
    }

    private func chip(_ day: Date, selected: Bool) -> some View {
        let key = day.timeIntervalSince1970
        let isToday = calendar.isDateInToday(day)
        return Button {
            select(day)
        } label: {
            VStack(spacing: 2) {
                Text(isToday ? "TODAY" : day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selected ? .black.opacity(0.7) : GlassTheme.tertiary)
                Text(day.formatted(.dateTime.day()))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(selected ? .black : GlassTheme.primary)
                if let count = counts[key], count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? .black.opacity(0.7) : GlassTheme.secondary)
                } else {
                    Text(" ").font(.caption2)
                }
            }
            .fontDesign(.rounded)
            .frame(minWidth: 58, minHeight: 66)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                        .fill(GlassTheme.accent)
                } else {
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                        .fill(GlassTheme.surface)
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                        .strokeBorder(GlassTheme.separator, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue(counts[key].map { "\($0) detections" } ?? "")
    }
}

/// The visual index Nest gets right: every detection of the loaded days as a thumbnail you
/// can flick through and tap, newest first. The card nearest the playhead is outlined.
private struct MomentsStrip: View {
    /// Newest first (pre-sorted by the owner, once per data change).
    let items: [FrigateEvent]
    let engine: TimelineEngine
    /// The moment card to scroll into view after a deliberate jump.
    let focusID: String?
    let thumbURL: (String) -> URL?
    let jump: (FrigateEvent) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let c = engine.center
        let nearestID = items.min { abs(($0.startTime ?? 0) - c) < abs(($1.startTime ?? 0) - c) }?.id
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: GlassTheme.Space.s) {
                    ForEach(items) { event in
                        MomentCard(event: event, highlighted: event.id == nearestID,
                                   thumbURL: thumbURL(event.id), jump: jump)
                            .id(event.id)
                    }
                }
                .padding(.horizontal, GlassTheme.Space.l)
            }
            .frame(height: 74)
            .onChange(of: focusID) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct MomentCard: View {
    let event: FrigateEvent
    let highlighted: Bool
    let thumbURL: URL?
    let jump: (FrigateEvent) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            Haptics.tap()
            jump(event)
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let thumbURL {
                    RemoteImage(url: thumbURL, contentMode: .fill)
                } else {
                    GlassTheme.surfaceHigh
                }
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 4) {
                    Circle()
                        .fill(TimelineStyle.color(for: event.label))
                        .frame(width: 6, height: 6)
                    Text(Date(timeIntervalSince1970: event.startTime ?? 0)
                            .formatted(.dateTime.hour().minute()))
                        .font(.caption2.weight(.bold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .padding(6)
            }
            .frame(width: 104, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                    .strokeBorder(highlighted ? GlassTheme.accent : GlassTheme.separator,
                                  lineWidth: highlighted ? 2 : 1)
            }
            .scaleEffect(highlighted ? 1.0 : 0.96)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: highlighted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(titleize(event.displayLabel)) at \(Date(timeIntervalSince1970: event.startTime ?? 0).formatted(date: .omitted, time: .shortened))")
    }
}

/// Minimal AVPlayerLayer host for the scrub preview — fills its frame, muted, no controls: purely a
/// surface the timelapse frames land on while the finger drags.
private struct PreviewPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
