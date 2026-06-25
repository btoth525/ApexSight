import SwiftUI

struct NotificationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var prefsStore: NotificationPreferencesStore
    @State private var status = NotificationStatus(isAuthorized: false, description: "Checking")

    init(prefsStore: NotificationPreferencesStore) {
        _prefsStore = ObservedObject(wrappedValue: prefsStore)
    }
    @State private var message: String?
    @State private var isWorking = false

    private func binding<T>(_ keyPath: WritableKeyPath<NotificationPreferences, T>) -> Binding<T> {
        Binding(
            get: { prefsStore.preferences[keyPath: keyPath] },
            set: { prefsStore.preferences[keyPath: keyPath] = $0; prefsStore.save() }
        )
    }

    var body: some View {
        ZStack {
            GlassTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    permissionCard
                    if status.isAuthorized {
                        camerasCard
                        objectsCard
                        zonesCard
                        quietHoursCard
                        cooldownCard
                        testCard
                    }
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task { status = await NativeNotificationManager.status() }
        // Re-check when returning from iOS Settings — the user may have just toggled
        // notification permission there, and the card should reflect it immediately.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { status = await NativeNotificationManager.status() }
            }
        }
    }

    // MARK: - Permission Card

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                HStack(spacing: GlassTheme.Space.m) {
                    Image(systemName: status.isAuthorized ? "bell.badge.fill" : "bell.slash.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(status.isAuthorized ? GlassTheme.green : GlassTheme.orange)
                        .frame(width: 38, height: 38)
                        .background((status.isAuthorized ? GlassTheme.green : GlassTheme.orange).opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                        Text("Push Notifications")
                            .font(.headline)
                            .foregroundStyle(GlassTheme.primary)
                        HStack(spacing: GlassTheme.Space.s) {
                            StatusDot(state: status.isAuthorized ? .live : .offline)
                            Text(status.description)
                                .font(.subheadline)
                                .foregroundStyle(GlassTheme.secondary)
                        }
                    }
                    Spacer()
                }

                if !status.isAuthorized {
                    Button {
                        Task { await requestPermission() }
                    } label: {
                        Label("Allow Notifications", systemImage: "checkmark.shield.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                    .disabled(isWorking)
                }
            }
        }
    }

    // MARK: - Cameras Card

    private var camerasCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                SectionHeader("Cameras")
                if appState.cameras.isEmpty {
                    placeholderText("No cameras loaded.")
                }
                ForEach(appState.cameras) { camera in
                    toggleRow(
                        title: titleize(camera.name),
                        subtitle: "\(camera.zones.count) zones · \(camera.objects.count) objects",
                        isOn: Binding(
                            get: { prefsStore.preferences.isCameraEnabled(camera.name) },
                            set: { prefsStore.preferences.cameraEnabled[camera.name] = $0; prefsStore.save() }
                        )
                    )
                }
            }
        }
    }

    // MARK: - Objects Card

    private var objectsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                SectionHeader("Object Types")
                if appState.labels.isEmpty {
                    placeholderText("No labels loaded.")
                }
                ForEach(appState.labels, id: \.self) { label in
                    toggleRow(
                        title: "\(NotificationCopy.emoji(for: label)) \(titleize(label))",
                        subtitle: nil,
                        isOn: Binding(
                            get: { prefsStore.preferences.isObjectEnabled(label) },
                            set: { prefsStore.preferences.objectEnabled[label] = $0; prefsStore.save() }
                        )
                    )
                }
            }
        }
    }

    // MARK: - Zones Card

    private var zonesCard: some View {
        let allZones = Array(Set(appState.cameras.flatMap(\.zones))).sorted()
        return GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                SectionHeader("Zones")
                if allZones.isEmpty {
                    placeholderText("No zones configured.")
                }
                ForEach(allZones, id: \.self) { zone in
                    toggleRow(
                        title: titleize(zone),
                        subtitle: nil,
                        isOn: Binding(
                            get: { prefsStore.preferences.isZoneEnabled(zone) },
                            set: { prefsStore.preferences.zoneEnabled[zone] = $0; prefsStore.save() }
                        )
                    )
                }
            }
        }
    }

    // MARK: - Quiet Hours Card

    private var quietHoursCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                SectionHeader("Quiet Hours")
                toggleRow(
                    title: "Enable quiet hours",
                    subtitle: "Suppress notifications during set hours",
                    isOn: binding(\.quietHoursEnabled)
                )
                if prefsStore.preferences.quietHoursEnabled {
                    Divider().overlay(GlassTheme.separator)
                    DatePicker("Start", selection: quietStartBinding, displayedComponents: .hourAndMinute)
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.primary)
                        .tint(GlassTheme.accent)
                    DatePicker("End", selection: quietEndBinding, displayedComponents: .hourAndMinute)
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.primary)
                        .tint(GlassTheme.accent)
                }
            }
        }
    }

    // MARK: - Cooldown Card

    private var cooldownCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                SectionHeader("Alert Cooldown", subtitle: "Minimum seconds between alerts per camera")
                ForEach(appState.cameras) { camera in
                    HStack {
                        Text(titleize(camera.name))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GlassTheme.primary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { prefsStore.preferences.cooldown(for: camera.name) },
                            set: { prefsStore.preferences.cooldownSeconds[camera.name] = $0; prefsStore.save() }
                        )) {
                            ForEach([0, 15, 30, 60, 120, 300], id: \.self) { s in
                                Text(s == 0 ? "None" : "\(s)s").tag(s)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(GlassTheme.accent)
                    }
                }
            }
        }
    }

    // MARK: - Test Card

    private var testCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                SectionHeader("Test")
                if let msg = message {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.secondary)
                }
                Button {
                    Task { await sendTest() }
                } label: {
                    HStack(spacing: GlassTheme.Space.s) {
                        if isWorking { ProgressView().tint(.white) }
                        Text("Send Test Alert")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                .disabled(isWorking)
            }
        }
    }

    // MARK: - Helpers

    private func toggleRow(title: String, subtitle: String?, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                if let sub = subtitle {
                    Text(sub)
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .tint(GlassTheme.accent)
                .labelsHidden()
        }
    }

    private func placeholderText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(GlassTheme.secondary)
    }

    private var quietStartBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: prefsStore.preferences.quietHoursStartHour,
                    minute: prefsStore.preferences.quietHoursStartMinute,
                    second: 0, of: Date()
                ) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                prefsStore.preferences.quietHoursStartHour = c.hour ?? 22
                prefsStore.preferences.quietHoursStartMinute = c.minute ?? 0
                prefsStore.save()
            }
        )
    }

    private var quietEndBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: prefsStore.preferences.quietHoursEndHour,
                    minute: prefsStore.preferences.quietHoursEndMinute,
                    second: 0, of: Date()
                ) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                prefsStore.preferences.quietHoursEndHour = c.hour ?? 7
                prefsStore.preferences.quietHoursEndMinute = c.minute ?? 0
                prefsStore.save()
            }
        )
    }

    private func requestPermission() async {
        isWorking = true
        defer { isWorking = false }
        _ = try? await NativeNotificationManager.requestPermission()
        status = await NativeNotificationManager.status()
        message = status.isAuthorized ? "Notifications are ready." : "Could not enable notifications — check Settings."
    }

    private func sendTest() async {
        isWorking = true
        defer { isWorking = false }
        // Use the most recent review for the full rich preview (GIF + deep link), exactly as
        // a real alert looks. `asTest` gives each tap a unique id + short trigger so repeated
        // taps reliably present (a stable per-review id would be coalesced silently).
        if let review = appState.reviews.first,
           let client = appState.client,
           let session = appState.session {
            await LocalAlertNotifier.notify(review: review, client: client, session: session, asTest: true)
            message = "Rich test alert sent (with preview) — lock your phone to see it on the Lock Screen."
        } else {
            // No event cached yet — send a basic sample so the user can still verify delivery.
            try? await NativeNotificationManager.sendTestNotification()
            message = "Test alert sent — lock your phone to see it. Trigger a real event to preview the GIF."
        }
    }
}
