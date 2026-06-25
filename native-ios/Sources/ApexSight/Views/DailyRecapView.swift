import SwiftUI

/// A "here's what happened today" summary of your cameras, with an optional daily
/// notification. Computed live from Frigate events — no cloud, no LLM round-trip.
struct DailyRecapView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var styleStore = NotificationStyleStore()

    @State private var recap: DailyRecap?
    @State private var loading = true

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
                    if let recap, !recap.isEmpty {
                        statsCard(recap)
                        objectsCard(recap)
                        camerasCard(recap)
                    } else if !loading {
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
            }
        }
        .navigationTitle("Daily Recap")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task { await load() }
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
                    ProgressView().tint(GlassTheme.accent)
                } else {
                    Text(recap?.headline ?? "All quiet today")
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

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = appState.client else { return }
        let events = await RecapBuilder.fetchToday(client: client)
        recap = RecapBuilder.build(events: events, style: styleStore.style)
    }
}
