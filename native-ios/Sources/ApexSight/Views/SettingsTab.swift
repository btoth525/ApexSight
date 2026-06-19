import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var path = NavigationPath()
    @AppStorage("colorSchemePreference") private var colorSchemePreference = "dark"
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppLockController.preferenceKey) private var biometricLockEnabled = false
    @State private var showAccountSheet = false
    @State private var accountSignedIn = DeviceTokenStore.isSignedInToAccount
    @State private var accountEmail = DeviceTokenStore.accountEmail
    @AppStorage("apex.armMode", store: UserDefaults(suiteName: ApexAppGroup.identifier))
    private var armModeRaw = ArmMode.away.rawValue

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        // Server info card
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Server")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(GlassTheme.primary)
                                if let session = appState.session {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(appState.isLive ? GlassTheme.green : GlassTheme.tertiary)
                                            .frame(width: 8, height: 8)
                                        Text(appState.isLive ? "Connected" : "Disconnected")
                                            .font(.system(size: 12, weight: .black))
                                            .foregroundStyle(appState.isLive ? GlassTheme.green : GlassTheme.secondary)
                                    }
                                    HStack {
                                        Image(systemName: "server.rack")
                                            .foregroundStyle(GlassTheme.cyan)
                                        Text(session.baseURL.absoluteString)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(GlassTheme.secondary)
                                            .lineLimit(1)
                                    }
                                    HStack {
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(GlassTheme.cyan)
                                        Text(session.username)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(GlassTheme.secondary)
                                    }
                                }
                                HStack(spacing: 12) {
                                    Button {
                                        path.append("servers")
                                    } label: {
                                        Label("Switch Server", systemImage: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 13, weight: .heavy))
                                    }
                                    .buttonStyle(PillButtonStyle(tint: GlassTheme.blue))

                                    Button(role: .destructive) {
                                        appState.signOut()
                                    } label: {
                                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                            .font(.system(size: 13, weight: .heavy))
                                    }
                                    .buttonStyle(PillButtonStyle(tint: GlassTheme.red))
                                }
                            }
                        }

                        // ApexSight account — drives private, per-account push routing.
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: accountSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                                        .font(.system(size: 16, weight: .black))
                                        .foregroundStyle(accountSignedIn ? GlassTheme.green : GlassTheme.cyan)
                                    Text("Account")
                                        .font(.system(size: 18, weight: .black))
                                        .foregroundStyle(GlassTheme.primary)
                                }
                                if accountSignedIn {
                                    Text(accountEmail ?? "Signed in")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(GlassTheme.secondary)
                                        .lineLimit(1)
                                    Button(role: .destructive) {
                                        DeviceTokenStore.signOutAccount()
                                        accountSignedIn = false
                                        accountEmail = nil
                                    } label: {
                                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                            .font(.system(size: 13, weight: .heavy))
                                    }
                                    .buttonStyle(PillButtonStyle(tint: GlassTheme.red))
                                } else {
                                    Text("Sign in to receive alerts on this device, routed privately to your account.")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(GlassTheme.secondary)
                                    Button {
                                        showAccountSheet = true
                                    } label: {
                                        Label("Sign In / Sign Up", systemImage: "person.badge.key.fill")
                                            .font(.system(size: 13, weight: .heavy))
                                    }
                                    .buttonStyle(PillButtonStyle(tint: GlassTheme.cyan))
                                }
                            }
                        }

                        // Security / Arm card
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: (ArmMode(rawValue: armModeRaw) ?? .away).systemImage)
                                        .font(.system(size: 16, weight: .black))
                                        .foregroundStyle(armModeRaw == ArmMode.disarmed.rawValue ? GlassTheme.red : GlassTheme.green)
                                    Text("Security")
                                        .font(.system(size: 18, weight: .black))
                                        .foregroundStyle(GlassTheme.primary)
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
                                Text(armModeRaw == ArmMode.disarmed.rawValue
                                     ? "Disarmed — all alerts are silenced."
                                     : "Armed — alerts are on. Change from here, Control Center, or “Hey Siri, disarm ApexSight.”")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(armModeRaw == ArmMode.disarmed.rawValue ? GlassTheme.orange : GlassTheme.secondary)
                            }
                        }

                        // Appearance card
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Appearance")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(GlassTheme.primary)
                                HStack(spacing: 10) {
                                    appearanceOption(label: "System", icon: "circle.lefthalf.filled", value: "system")
                                    appearanceOption(label: "Dark", icon: "moon.fill", value: "dark")
                                    appearanceOption(label: "Light", icon: "sun.max.fill", value: "light")
                                }
                            }
                        }

                        // Privacy / app lock card — only when the device can authenticate.
                        if BiometricLock.isAvailable {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Toggle(isOn: $biometricLockEnabled) {
                                        HStack(spacing: 10) {
                                            Image(systemName: BiometricLock.symbolName)
                                                .font(.system(size: 18, weight: .black))
                                                .foregroundStyle(GlassTheme.cyan)
                                                .frame(width: 30)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Require \(BiometricLock.label)")
                                                    .font(.system(size: 16, weight: .black))
                                                    .foregroundStyle(GlassTheme.primary)
                                                Text("Lock the app when you leave it.")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(GlassTheme.secondary)
                                            }
                                        }
                                    }
                                    .tint(GlassTheme.cyan)
                                    .sensoryFeedback(.selection, trigger: biometricLockEnabled)
                                }
                            }
                        }

                        // Quick nav cards
                        settingsRow(icon: "waveform.path.ecg", title: "System Health", subtitle: "Cameras, detectors, storage", tint: GlassTheme.green) {
                            path.append("system")
                        }
                        settingsRow(icon: "bell.badge.fill", title: "Notifications", subtitle: "Per-camera preferences, quiet hours", tint: GlassTheme.orange) {
                            path.append("notifications")
                        }
                        settingsRow(icon: "paintbrush.pointed.fill", title: "Alert Style", subtitle: "Emojis, fields, snapshot → GIF, buttons", tint: GlassTheme.teal) {
                            path.append("style")
                        }
                        settingsRow(icon: "bolt.horizontal.fill", title: "Instant Push", subtitle: "Status & test for alerts when closed", tint: GlassTheme.cyan) {
                            path.append("push")
                        }
                        settingsRow(icon: "slider.horizontal.3", title: "Triggers", subtitle: "Custom notification rules by camera, object, zone", tint: GlassTheme.purple) {
                            path.append("triggers")
                        }
                        settingsRow(icon: "person.crop.square.filled.and.at.rectangle", title: "People & Faces", subtitle: "Name faces → \"Alex arrived\" instead of \"person\"", tint: GlassTheme.green) {
                            path.append("faces")
                        }
                        settingsRow(icon: "car.fill", title: "License Plates", subtitle: "Name your cars → \"Unknown plate\" for the rest", tint: GlassTheme.blue) {
                            path.append("plates")
                        }
                        settingsRow(icon: "doc.text.image.fill", title: "Daily Recap", subtitle: "Today's activity + an optional daily summary", tint: GlassTheme.orange) {
                            path.append("recap")
                        }

                        // About card
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("About")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(GlassTheme.primary)
                                HStack {
                                    Image(systemName: "shield.lefthalf.filled")
                                        .foregroundStyle(GlassTheme.cyan)
                                    Text("ApexSight")
                                        .font(.system(size: 14, weight: .heavy))
                                        .foregroundStyle(GlassTheme.primary)
                                    Spacer()
                                    Text(appVersion)
                                        .font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(GlassTheme.secondary)
                                }
                                Text("Native Frigate NVR client. Local-first — no accounts, no telemetry.")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(GlassTheme.secondary)
                                Button {
                                    hasCompletedOnboarding = false
                                } label: {
                                    Label("Replay Intro", systemImage: "sparkles")
                                        .font(.system(size: 13, weight: .heavy))
                                }
                                .buttonStyle(PillButtonStyle(tint: GlassTheme.purple))
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .glassNavBar()
            .sheet(isPresented: $showAccountSheet, onDismiss: {
                accountSignedIn = DeviceTokenStore.isSignedInToAccount
                accountEmail = DeviceTokenStore.accountEmail
            }) {
                AccountSignInView(onSignedIn: {
                    accountSignedIn = true
                    accountEmail = DeviceTokenStore.accountEmail
                })
            }
            .navigationDestination(for: String.self) { value in
                if value == "system" { SystemHealthView() }
                else if value == "notifications" { NotificationSettingsView(prefsStore: appState.notificationPrefs) }
                else if value == "style" { AlertStyleView() }
                else if value == "servers" { ServerSwitcherView() }
                else if value == "push" { PushCompanionSettingsView() }
                else if value == "triggers" { TriggersSettingsView(store: appState.triggerStore).environmentObject(appState) }
                else if value == "plates" { PlateManagerView().environmentObject(appState) }
                else if value == "faces" { FaceManagerView().environmentObject(appState) }
                else if value == "recap" { DailyRecapView().environmentObject(appState) }
            }
        }
    }

    private func appearanceOption(label: String, icon: String, value: String) -> some View {
        let selected = colorSchemePreference == value
        return Button {
            Haptics.select()
            colorSchemePreference = value
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(selected ? Color.black : GlassTheme.primary)
                    .frame(width: 48, height: 48)
                    .background(selected ? GlassTheme.cyan : .white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(label)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(selected ? GlassTheme.cyan : GlassTheme.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func settingsRow(icon: String, title: String, subtitle: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); action() }) {
            GlassCard {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(tint)
                        .frame(width: 44, height: 44)
                        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(GlassTheme.primary)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
