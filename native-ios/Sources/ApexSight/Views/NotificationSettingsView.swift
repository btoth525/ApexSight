import SwiftUI

struct NotificationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var prefsStore = NotificationPreferencesStore()
    @State private var status = NotificationStatus(isAuthorized: false, description: "Checking")
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
                VStack(alignment: .leading, spacing: 18) {
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
                .padding(18)
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task { status = await NativeNotificationManager.status() }
    }

    // MARK: - Permission Card

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: status.isAuthorized ? "bell.badge.fill" : "bell.slash.fill")
                        .font(.system(size: 20, weight: .900))
                        .foregroundStyle(status.isAuthorized ? GlassTheme.green : GlassTheme.orange)
                        .frame(width: 36, height: 36)
                        .background((status.isAuthorized ? GlassTheme.green : GlassTheme.orange).opacity(0.16), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Push Notifications")
                            .font(.system(size: 16, weight: .900))
                            .foregroundStyle(GlassTheme.primary)
                        Text(status.description)
                            .font(.system(size: 12, weight: .800))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                    Spacer()
                }

                if !status.isAuthorized {
                    Button {
                        Task { await requestPermission() }
                    } label: {
                        Label("Allow Notifications", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 15, weight: .900))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(GlassTheme.cyan, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }
            }
        }
    }

    // MARK: - Cameras Card

    private var camerasCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Cameras", icon: "video.fill", tint: GlassTheme.blue)
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
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Object Types", icon: "eye.fill", tint: GlassTheme.green)
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
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Zones", icon: "map.fill", tint: GlassTheme.cyan)
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
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Quiet Hours", icon: "moon.fill", tint: GlassTheme.orange)
                toggleRow(
                    title: "Enable quiet hours",
                    subtitle: "Suppress notifications during set hours",
                    isOn: binding(\.quietHoursEnabled)
                )
                if prefsStore.preferences.quietHoursEnabled {
                    Divider().background(GlassTheme.secondary.opacity(0.2))
                    DatePicker("Start", selection: quietStartBinding, displayedComponents: .hourAndMinute)
                        .font(.system(size: 14, weight: .800))
                        .foregroundStyle(GlassTheme.primary)
                        .tint(GlassTheme.cyan)
                    DatePicker("End", selection: quietEndBinding, displayedComponents: .hourAndMinute)
                        .font(.system(size: 14, weight: .800))
                        .foregroundStyle(GlassTheme.primary)
                        .tint(GlassTheme.cyan)
                }
            }
        }
    }

    // MARK: - Cooldown Card

    private var cooldownCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Alert Cooldown", icon: "timer", tint: GlassTheme.secondary)
                Text("Minimum seconds between alerts per camera")
                    .font(.system(size: 12, weight: .700))
                    .foregroundStyle(GlassTheme.secondary)
                ForEach(appState.cameras) { camera in
                    HStack {
                        Text(titleize(camera.name))
                            .font(.system(size: 14, weight: .800))
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
                        .tint(GlassTheme.cyan)
                    }
                }
            }
        }
    }

    // MARK: - Test Card

    private var testCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Test", icon: "paperplane.fill", tint: GlassTheme.blue)
                if let msg = message {
                    Text(msg)
                        .font(.system(size: 13, weight: .800))
                        .foregroundStyle(GlassTheme.green)
                }
                Button {
                    Task { await sendTest() }
                } label: {
                    HStack {
                        if isWorking { ProgressView().tint(.black) }
                        Text("Send Test Alert")
                            .font(.system(size: 15, weight: .900))
                            .foregroundStyle(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(GlassTheme.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .900))
            .foregroundStyle(tint)
    }

    private func toggleRow(title: String, subtitle: String?, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .800))
                    .foregroundStyle(GlassTheme.primary)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11, weight: .700))
                        .foregroundStyle(GlassTheme.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .tint(GlassTheme.cyan)
                .labelsHidden()
        }
    }

    private func placeholderText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .700))
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
        do {
            try await NativeNotificationManager.sendTestNotification()
            message = "Test alert sent — check your lock screen."
        } catch {
            message = error.localizedDescription
        }
    }
}
