import SwiftUI

/// A "here's what happened today" summary of your cameras, with an optional daily
/// notification. Computed live from Frigate events — no cloud, no LLM round-trip.
struct DailyRecapView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var styleStore = NotificationStyleStore()

    @State private var recap: DailyRecap?
    @State private var loading = true
    // Distinguishes a failed fetch ("couldn't load") from a genuinely quiet day
    // ("all quiet") so we can offer a retry instead of implying nothing happened.
    @State private var loadFailed = false

    /// On-device AI summary of the day (Apple Intelligence). Nil when AI is unavailable/disabled
    /// or still generating — the rest of the recap renders exactly as before either way.
    @State private var aiSummary: String?

    @AppStorage("apex.recap.enabled") private var recapEnabled = false
    @State private var recapTime = Calendar.current.date(
        from: DateComponents(hour: RecapSettings.hour, minute: RecapSettings.minute)
    ) ?? Date()

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(spacing: GlassTheme.Space.l) {
                    heroCard
                    if loading {
                        loadingSkeleton
                    } else if loadFailed {
                        errorCard
                    } else if let recap, !recap.isEmpty {
                        if let aiSummary { aiSummaryCard(aiSummary) }
                        statsCard(recap)
                        objectsCard(recap)
                        camerasCard(recap)
                    } else {
                        GlassCard {
                            EmptyStateView(
                                icon: "checkmark.shield",
                                title: "All quiet today",
                                message: "No notable activity yet. Your recap will fill in as events come in."
                            )
                        }
                    }
                    scheduleCard
                }
                .padding(GlassTheme.Space.l)
                .animation(.easeInOut(duration: 0.25), value: loading)
                .animation(.easeInOut(duration: 0.25), value: loadFailed)
            }
        }
        .navigationTitle("Daily Recap")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task {
            await load()
            await generateAISummary()
        }
    }

    /// Generate the on-device AI summary once the recap is loaded. No-op (leaves `aiSummary` nil,
    /// so the card simply doesn't appear) when Apple Intelligence is unavailable or disabled.
    private func generateAISummary() async {
#if canImport(FoundationModels)
        guard AppleAI.isAvailable, let recap, !recap.isEmpty else { return }
        guard #available(iOS 26, *) else { return }

        var facts: [String] = ["\(recap.total) total events today."]
        if !recap.people.isEmpty { facts.append("People recognized: \(recap.people.map(titleize).joined(separator: ", ")).") }
        if recap.packages > 0 { facts.append("\(recap.packages) package event(s).") }
        if let busiest = recap.busiestHourLabel { facts.append("Busiest around \(busiest).") }
        let topCams = recap.cameraCounts.prefix(4).map { "\(titleize($0.camera)) (\($0.count))" }
        if !topCams.isEmpty { facts.append("By camera: \(topCams.joined(separator: ", ")).") }
        let topLabels = recap.labelCounts.prefix(6).map { "\($0.label) \($0.count)" }
        if !topLabels.isEmpty { facts.append("By object: \(topLabels.joined(separator: ", ")).") }
        if !recap.carriers.isEmpty { facts.append("Carriers: \(recap.carriers.map { "\($0.name) \($0.count)" }.joined(separator: ", ")).") }

        let summary = await AppleAI.summarize(
            instructions: "You summarize a home's security events for the day in 2-3 short, plain, factual sentences. Note patterns like deliveries, known vs unknown people, and busy times. No alarmism, no identity guesses, no markdown.",
            prompt: "Today's activity:\n" + facts.joined(separator: "\n") + "\n\nWrite the summary."
        )
        if let summary, !Task.isCancelled { aiSummary = summary }
#endif
    }

    private func aiSummaryCard(_ text: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: "apple.intelligence").font(.caption)
                    Text("SUMMARY").font(.caption2).fontWeight(.semibold).tracking(0.8)
                }
                .foregroundStyle(GlassTheme.accent)
                Text(text)
                    .font(.body)
                    .foregroundStyle(GlassTheme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI summary. \(text)")
    }

    // MARK: - Cards

    private var heroCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                Text("TODAY")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .foregroundStyle(GlassTheme.tertiary)
                if loading {
                    SkeletonBlock().frame(width: 200, height: 26)
                        .accessibilityHidden(true)
                } else {
                    Text(loadFailed ? "Couldn't load today" : (recap?.headline ?? "All quiet today"))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(GlassTheme.primary)
                    if let recap, let first = recap.firstAt, let last = recap.lastAt, !recap.isEmpty {
                        Text("First \(first.formatted(date: .omitted, time: .shortened)) · Latest \(last.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statsCard(_ recap: DailyRecap) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Highlights")
                let stats = chips(recap)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: GlassTheme.Space.s), GridItem(.flexible())], spacing: GlassTheme.Space.s) {
                    ForEach(stats, id: \.label) { stat in
                        VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                            HStack(spacing: GlassTheme.Space.s) {
                                Circle()
                                    .fill(stat.tint)
                                    .frame(width: 7, height: 7)
                                Text(stat.value)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(GlassTheme.primary)
                            }
                            Text(stat.label)
                                .font(.footnote)
                                .foregroundStyle(GlassTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(GlassTheme.Space.m)
                        .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                        .cardStroke(GlassTheme.Radius.tile)
                    }
                }
                if !recap.people.isEmpty {
                    HStack(spacing: GlassTheme.Space.s) {
                        StatusDot(state: .live)
                        Text(recap.people.map(titleize).joined(separator: ", "))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
            }
        }
    }

    private struct Stat { let label: String; let value: String; let tint: Color }

    private func chips(_ recap: DailyRecap) -> [Stat] {
        var out: [Stat] = [Stat(label: "Events", value: "\(recap.total)", tint: GlassTheme.accent)]
        out.append(Stat(label: "People seen", value: "\(recap.people.count)", tint: GlassTheme.green))
        if recap.packages > 0 { out.append(Stat(label: "Packages", value: "\(recap.packages)", tint: GlassTheme.orange)) }
        if let busiest = recap.busiestHourLabel { out.append(Stat(label: "Busiest", value: busiest, tint: GlassTheme.accent)) }
        return out
    }

    private func objectsCard(_ recap: DailyRecap) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("By Object")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: GlassTheme.Space.s)], spacing: GlassTheme.Space.s) {
                    ForEach(recap.labelCounts.prefix(12), id: \.label) { item in
                        objectChip(NotificationCopy.emoji(for: item.label), titleize(item.label), item.count, tint: GlassTheme.accent)
                    }
                }
                if !recap.carriers.isEmpty {
                    Text("DELIVERIES")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .tracking(0.8)
                        .foregroundStyle(GlassTheme.tertiary)
                        .padding(.top, GlassTheme.Space.xs)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: GlassTheme.Space.s)], spacing: GlassTheme.Space.s) {
                        ForEach(recap.carriers, id: \.name) { item in
                            objectChip(NotificationCopy.emoji(for: "package", subLabel: item.name), titleize(item.name), item.count, tint: GlassTheme.orange)
                        }
                    }
                }
            }
        }
    }

    private func objectChip(_ emoji: String, _ title: String, _ count: Int, tint: Color) -> some View {
        HStack(spacing: GlassTheme.Space.xs) {
            Text("\(emoji) \(title)")
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundStyle(GlassTheme.primary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text("\(count)")
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, GlassTheme.Space.m)
        .padding(.vertical, GlassTheme.Space.s)
        .background(GlassTheme.surfaceHigh, in: Capsule())
        .overlay { Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1) }
    }

    private func camerasCard(_ recap: DailyRecap) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("By Camera")
                let maxCount = recap.cameraCounts.first?.count ?? 1
                ForEach(recap.cameraCounts.prefix(8), id: \.camera) { item in
                    VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                        HStack {
                            Text(titleize(item.camera))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(GlassTheme.primary)
                            Spacer()
                            Text("\(item.count)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(GlassTheme.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(GlassTheme.surfaceHigh)
                                Capsule()
                                    .fill(GlassTheme.accent)
                                    .frame(width: geo.size.width * CGFloat(item.count) / CGFloat(max(maxCount, 1)))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    private var scheduleCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Daily Notification")
                Toggle(isOn: $recapEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send a daily recap")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(GlassTheme.primary)
                        Text("A summary notification each day")
                            .font(.footnote)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
                .tint(GlassTheme.accent)
                .sensoryFeedback(.selection, trigger: recapEnabled)
                .onChange(of: recapEnabled) { _, isOn in
                    // A recap is useless without notification permission — ask the
                    // moment the user opts in (no-op if already granted/denied).
                    if isOn { Task { _ = try? await NativeNotificationManager.requestPermission() } }
                    // Push the schedule to the relay so it fires even with the app closed.
                    appState.syncRecapIfChanged()
                }

                if recapEnabled {
                    Divider().overlay(GlassTheme.separator)
                    DatePicker("Time", selection: $recapTime, displayedComponents: .hourAndMinute)
                        .font(.subheadline)
                        .tint(GlassTheme.accent)
                        .onChange(of: recapTime) { _, newValue in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                            RecapSettings.hour = c.hour ?? 21
                            RecapSettings.minute = c.minute ?? 0
                            appState.syncRecapIfChanged()
                        }
                }
                Text("Delivered around your chosen time when the app refreshes in the background.")
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.tertiary)
            }
        }
    }

    // MARK: - Loading & Error states

    /// Skeleton that mirrors the highlights grid while today's events are fetched,
    /// instead of a lone spinner floating in the hero.
    private var loadingSkeleton: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SkeletonBlock().frame(width: 110, height: 17)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: GlassTheme.Space.s), GridItem(.flexible())], spacing: GlassTheme.Space.s) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonBlock(cornerRadius: GlassTheme.Radius.tile).frame(height: 64)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// A calm error banner with a one-tap retry, shown when the recap fetch fails so
    /// the user never confuses a network problem with a genuinely quiet day.
    private var errorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                HStack(alignment: .top, spacing: GlassTheme.Space.m) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(GlassTheme.orange)
                        .frame(width: 38, height: 38)
                        .background(GlassTheme.orange.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                        Text("Couldn't load today's recap")
                            .font(.headline)
                            .foregroundStyle(GlassTheme.primary)
                        Text("Check your connection to Frigate and try again.")
                            .font(.footnote)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    Haptics.tap()
                    Task { await load() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                .disabled(loading)
            }
        }
    }

    private func load() async {
        loading = true
        loadFailed = false
        defer { loading = false }
        guard let client = appState.client else {
            loadFailed = true
            return
        }
        // Fetch directly (rather than via RecapBuilder.fetchToday, which swallows errors)
        // so we can surface a retryable error state instead of a misleading "all quiet".
        do {
            let start = Calendar.current.startOfDay(for: Date())
            let events = try await client.events(after: start, before: Date(), limit: 500)
            recap = RecapBuilder.build(events: events, style: styleStore.style)
        } catch {
            loadFailed = true
        }
    }
}
