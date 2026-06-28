import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var path = NavigationPath()
    @AppStorage("colorSchemePreference") private var colorSchemePreference = "dark"
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppLockController.preferenceKey) private var biometricLockEnabled = false
    @AppStorage("apex.armMode", store: UserDefaults(suiteName: ApexAppGroup.identifier))
    private var armModeRaw = ArmMode.away.rawValue
    @State private var showSignOutConfirm = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var isDisarmed: Bool { armModeRaw == ArmMode.disarmed.rawValue }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(spacing: GlassTheme.Space.l) {
                        serverCard
                        securityCard
                        appearanceCard

                        // Privacy / app lock card — only when the device can authenticate.
                        if BiometricLock.isAvailable {
                            privacyCard
                        }

                        configurationSection
                        aboutCard
                    }
                    .padding(GlassTheme.Space.l)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .navigationDestination(for: String.self) { value in
                if value == "system" { SystemHealthView() }
                else if value == "notifications" { NotificationSettingsView(prefsStore: appState.notificationPrefs) }
                else if value == "style" { AlertStyleView() }
                else if value == "servers" { ServerSwitcherView() }
                else if value == "push" { PushCompanionSettingsView() }
                else if value == "triggers" { TriggersSettingsView(store: appState.triggerStore).environmentObject(appState) }
                else if value == "recap" { DailyRecapView().environmentObject(appState) }
            }
        }
    }

    // MARK: - Server

    private var serverCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Server")

                if let session = appState.session {
                    HStack(spacing: GlassTheme.Space.s) {
                        StatusDot(state: appState.isLive ? .live : .offline)
                        Text(appState.isLive ? "Connected" : "Disconnected")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(appState.isLive ? GlassTheme.green : GlassTheme.secondary)
                    }

                    VStack(spacing: GlassTheme.Space.s) {
                        infoRow(icon: "server.rack", text: session.baseURL.absoluteString)
                        infoRow(icon: "person.fill", text: session.username)
                    }
                }

                HStack(spacing: GlassTheme.Space.m) {
                    Button {
                        Haptics.tap()
                        path.append("servers")
                    } label: {
                        Label("Switch Server", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))

                    Button(role: .destructive) {
                        Haptics.warning()
                        showSignOutConfirm = true
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.red))
                }
                .padding(.top, GlassTheme.Space.xs)
            }
        }
        // Signing out clears the keychain session — guard the accidental tap.
        .confirmationDialog("Sign out of this server?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { appState.signOut() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: GlassTheme.Space.m) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(GlassTheme.tertiary)
                .frame(width: 22)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(GlassTheme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Security / Arm

    private var securityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Security") {
                    Image(systemName: (ArmMode(rawValue: armModeRaw) ?? .away).systemImage)
                        .font(.headline)
                        .foregroundStyle(isDisarmed ? GlassTheme.red : GlassTheme.green)
                }

                Picker("Mode", selection: $armModeRaw) {
                    ForEach(ArmMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: armModeRaw) { _, newValue in
                    // Route through ArmStateStore so the home/Lock-Screen
                    // widgets + Control Center toggle refresh immediately,
                    // and push the arm/snooze gate to the relay now (not on
                    // the next 15s poll).
                    let mode = ArmMode(rawValue: newValue) ?? .away
                    ArmStateStore.mode = mode
                    appState.syncRelayGateIfChanged()
                    // Feel the change: a firm "armed" success vs a softer "disarmed" warning.
                    if mode == .disarmed { Haptics.warning() } else { Haptics.success() }
                }

                Text(isDisarmed
                     ? "Disarmed — all alerts are silenced."
                     : "Armed — alerts are on. Change from here, Control Center, or “Hey Siri, disarm ApexSight.”")
                    .font(.footnote)
                    .foregroundStyle(isDisarmed ? GlassTheme.orange : GlassTheme.secondary)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Appearance")
                HStack(spacing: GlassTheme.Space.m) {
                    appearanceOption(label: "System", icon: "circle.lefthalf.filled", value: "system")
                    appearanceOption(label: "Dark", icon: "moon.fill", value: "dark")
                    appearanceOption(label: "Light", icon: "sun.max.fill", value: "light")
                }
            }
        }
    }

    // MARK: - Privacy / App Lock

    private var privacyCard: some View {
        GlassCard {
            Toggle(isOn: $biometricLockEnabled) {
                HStack(spacing: GlassTheme.Space.m) {
                    iconTile(systemName: BiometricLock.symbolName, tint: GlassTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Require \(BiometricLock.label)")
                            .font(.headline)
                            .foregroundStyle(GlassTheme.primary)
                        Text("Lock the app when you leave it.")
                            .font(.footnote)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
            }
            .tint(GlassTheme.accent)
            .sensoryFeedback(.selection, trigger: biometricLockEnabled)
        }
    }

    // MARK: - Configuration rows

    private var configurationSection: some View {
        VStack(spacing: GlassTheme.Space.m) {
            settingsRow(icon: "waveform.path.ecg", title: "System Health", subtitle: "Cameras, detectors, storage") {
                path.append("system")
            }
            settingsRow(icon: "bell.badge.fill", title: "Notifications", subtitle: "Per-camera preferences, quiet hours") {
                path.append("notifications")
            }
            settingsRow(icon: "paintbrush.pointed.fill", title: "Alert Style", subtitle: "Emojis, fields, snapshot → GIF, buttons") {
                path.append("style")
            }
            settingsRow(icon: "bolt.horizontal.fill", title: "Instant Push", subtitle: "Status & test for alerts when closed") {
                path.append("push")
            }
            settingsRow(icon: "slider.horizontal.3", title: "Triggers", subtitle: "Custom notification rules by camera, object, zone") {
                path.append("triggers")
            }
            settingsRow(icon: "doc.text.image.fill", title: "Daily Recap", subtitle: "Today's activity + an optional daily summary") {
                path.append("recap")
            }
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("About")

                HStack(spacing: GlassTheme.Space.m) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.headline)
                        .foregroundStyle(GlassTheme.accent)
                    Text("ApexSight")
                        .font(.headline)
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    Text(appVersion)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(GlassTheme.secondary)
                        .monospacedDigit()
                }

                Text("Native Frigate NVR client. Local-first — no accounts, no telemetry.")
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.secondary)

                Button {
                    Haptics.tap()
                    hasCompletedOnboarding = false
                } label: {
                    Label("Replay Intro", systemImage: "sparkles")
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                .padding(.top, GlassTheme.Space.xs)
            }
        }
    }

    // MARK: - Reusable pieces

    private func iconTile(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(.body, design: .default).weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
    }

    private func appearanceOption(label: String, icon: String, value: String) -> some View {
        let selected = colorSchemePreference == value
        return Button {
            Haptics.select()
            colorSchemePreference = value
        } label: {
            VStack(spacing: GlassTheme.Space.s) {
                Image(systemName: icon)
                    .font(.system(.title3, design: .default).weight(.semibold))
                    .foregroundStyle(selected ? Color.black : GlassTheme.primary)
                    .frame(width: 52, height: 52)
                    .background(
                        selected ? GlassTheme.accent : GlassTheme.surfaceHigh,
                        in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous)
                    )
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(selected ? GlassTheme.accent : GlassTheme.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) appearance")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func settingsRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); action() }) {
            GlassCard {
                HStack(spacing: GlassTheme.Space.l) {
                    iconTile(systemName: icon, tint: GlassTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(GlassTheme.primary)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                    Spacer(minLength: GlassTheme.Space.s)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(.isButton)
    }
}
