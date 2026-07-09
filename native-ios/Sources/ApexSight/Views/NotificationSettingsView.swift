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
    // First-load gate so we show a calm skeleton instead of flashing the "off" card
    // before the real authorization status comes back from the system.
    @State private var didLoadStatus = false

    private func binding<T>(_ keyPath: WritableKeyPath<NotificationPreferences, T>) -> Binding<T> {
        Binding(
            get: { prefsStore.preferences[keyPath: keyPath] },
            set: { prefsStore.preferences[keyPath: keyPath] = $0; prefsStore.save() }
        )
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    if !didLoadStatus {
                        loadingSkeleton
                    } else {
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
                }
                .padding(GlassTheme.Space.l)
                .animation(.easeInOut(duration: 0.25), value: status.isAuthorized)
                .animation(.easeInOut(duration: 0.25), value: didLoadStatus)
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task {
            status = await NativeNotificationManager.status()
            didLoadStatus = true
            // Propagate this device's current notification prefs to the relay so app-closed pushes
            // honor every mute/quiet-hours/trigger, not just foreground delivery.
            appState.syncDevicePrefs()
        }
        // Any notification-setting toggle (camera / object / zone / quiet hours / snooze) re-syncs
        // immediately so the relay's per-device gate matches without waiting for the foreground poll.
        .onChange(of: prefsStore.preferences) { _, _ in
            appState.syncDevicePrefs()
        }
        // Re-check when returning from iOS Settings — the user may have just toggled
        // notification permission there, and the card should reflect it immediately.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { status = await NativeNotificationManager.status() }
            }
        }
    }

    // MARK: - Loading

    /// A calm skeleton mirroring the permission + first content card while the system
    /// reports authorization status, instead of flashing the "notifications off" state.
    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
            GlassCard {
                HStack(spacing: GlassTheme.Space.m) {
                    SkeletonBlock(cornerRadius: 19).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                        SkeletonBlock().frame(width: 160, height: 15)
                        SkeletonBlock().frame(width: 100, height: 12)
                    }
                    Spacer(minLength: 0)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                    SkeletonBlock().frame(width: 120, height: 17)
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBlock().frame(height: 14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityHidden(true)
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
                        Haptics.tap()
                        Task { await requestPermission() }
                    } label: {
                        HStack(spacing: GlassTheme.Space.s) {
                            if isWorking { ProgressView().tint(.white) }
                            Label("Allow Notifications", systemImage: "checkmark.shield.fill")
                        }
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
                            set: {
                                prefsStore.preferences.cameraEnabled[camera.name] = $0
                                prefsStore.save()   // relay re-sync via .onChange(of: preferences)
                            }
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
                    Haptics.tap()
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
            Toggle(title, isOn: isOn)
                .tint(GlassTheme.accent)
                .labelsHidden()
                .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
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
        if status.isAuthorized { Haptics.success() } else { Haptics.warning() }
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
            Haptics.success()
        } else {
            // No event cached yet — send a basic sample so the user can still verify delivery.
            // Gate the success feedback on the send actually going through: the fallback can
            // throw (e.g. scheduling failure), and a haptic that buzzes anyway would be a lie.
            do {
                try await NativeNotificationManager.sendTestNotification()
                message = "Test alert sent — lock your phone to see it. Trigger a real event to preview the GIF."
                Haptics.success()
            } catch {
                message = "Couldn't send the test alert — check notification permission in Settings."
                Haptics.error()
            }
        }
    }
}
