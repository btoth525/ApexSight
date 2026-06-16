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
                VStack(spacing: 16) {
                    heroCard
                    if let recap, !recap.isEmpty {
                        statsCard(recap)
                        camerasCard(recap)
                    }
                    scheduleCard
                }
                .padding(16)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("TODAY")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(GlassTheme.tertiary)
                if loading {
                    ProgressView().tint(GlassTheme.cyan)
                } else {
                    Text(recap?.headline ?? "All quiet today")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(GlassTheme.primary)
                    if let recap, let first = recap.firstAt, let last = recap.lastAt, !recap.isEmpty {
                        Text("First \(first.formatted(date: .omitted, time: .shortened)) · Latest \(last.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
            }
        }
    }

    private func statsCard(_ recap: DailyRecap) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Highlights")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                let stats = chips(recap)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(stats, id: \.label) { stat in
                        VStack(spacing: 4) {
                            Text(stat.value)
                                .font(.system(size: 22, weight: .black, design: .rounded))
                                .foregroundStyle(stat.tint)
                            Text(stat.label)
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(GlassTheme.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                if !recap.people.isEmpty {
                    Text("👤 " + recap.people.map(titleize).joined(separator: ", "))
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(GlassTheme.green)
                }
            }
        }
    }

    private struct Stat { let label: String; let value: String; let tint: Color }

    private func chips(_ recap: DailyRecap) -> [Stat] {
        var out: [Stat] = [Stat(label: "Events", value: "\(recap.total)", tint: GlassTheme.cyan)]
        out.append(Stat(label: "People seen", value: "\(recap.people.count)", tint: GlassTheme.green))
        if recap.packages > 0 { out.append(Stat(label: "Packages", value: "\(recap.packages)", tint: GlassTheme.orange)) }
        if recap.unknownPlates > 0 { out.append(Stat(label: "Unknown plates", value: "\(recap.unknownPlates)", tint: GlassTheme.red)) }
        return out
    }

    private func camerasCard(_ recap: DailyRecap) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("By Camera")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                let maxCount = recap.cameraCounts.first?.count ?? 1
                ForEach(recap.cameraCounts.prefix(8), id: \.camera) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(titleize(item.camera))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(GlassTheme.primary)
                            Spacer()
                            Text("\(item.count)")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(GlassTheme.secondary)
                        }
                        GeometryReader { geo in
                            Capsule()
                                .fill(GlassTheme.cyan.opacity(0.8))
                                .frame(width: geo.size.width * CGFloat(item.count) / CGFloat(max(maxCount, 1)))
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    private var scheduleCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Daily Notification")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Toggle(isOn: $recapEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send a daily recap")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(GlassTheme.primary)
                        Text("A summary notification each day")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(GlassTheme.tertiary)
                    }
                }
                .tint(GlassTheme.cyan)
                .onChange(of: recapEnabled) { _, isOn in
                    // A recap is useless without notification permission — ask the
                    // moment the user opts in (no-op if already granted/denied).
                    guard isOn else { return }
                    Task { _ = try? await NativeNotificationManager.requestPermission() }
                }

                if recapEnabled {
                    DatePicker("Time", selection: $recapTime, displayedComponents: .hourAndMinute)
                        .tint(GlassTheme.cyan)
                        .onChange(of: recapTime) { _, newValue in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                            RecapSettings.hour = c.hour ?? 21
                            RecapSettings.minute = c.minute ?? 0
                        }
                }
                Text("Delivered around your chosen time when the app refreshes in the background.")
                    .font(.system(size: 11, weight: .semibold))
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
