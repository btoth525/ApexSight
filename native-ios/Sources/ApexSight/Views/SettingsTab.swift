import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var path = NavigationPath()
    // App-group store so the Notification Service Extension can read the master AI toggle.
    @AppStorage("appleIntelligenceEnabled", store: UserDefaults(suiteName: ApexAppGroup.identifier))
    private var appleIntelligenceEnabled = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(DiagnosticLog.enabledKey, store: UserDefaults(suiteName: ApexAppGroup.identifier))
    private var diagnosticsEnabled = true
    @AppStorage("spotlightEventsEnabled") private var spotlightEventsEnabled = true
    @AppStorage(AppLockController.preferenceKey) private var biometricLockEnabled = false
    @State private var showSignOutConfirm = false
    @State private var showConfigEditor = false
    @State private var showMyExports = false
    @State private var showRestartConfirm = false
    @State private var restartToast: String?
    /// Draft text for the optional home-network URL field (seeded from the saved session).
    @State private var localURLDraft = ""
    @FocusState private var localURLFocused: Bool

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
                    VStack(spacing: GlassTheme.Space.l) {
                        houseModeCard
                        serverCard
                        connectionCard
                        spotlightCard

                        // Apple Intelligence — only on devices that can actually run the model.
                        if AppleAI.deviceSupportsAI {
                            intelligenceCard
                        }

                        // Privacy / app lock card — only when the device can authenticate.
                        if BiometricLock.isAvailable {
                            privacyCard
                        }

                        doorbellTalkCard
                        configurationSection
                        serverToolsCard
                        diagnosticsCard
                        aboutCard

                        #if DEBUG
                        debugCard
                        #endif
                    }
                    .padding(GlassTheme.Space.l)
                }
                // Kill the rubber-band bounce when the content already fits (and prevent any
                // stray horizontal slide of the whole page reported at default text size).
                .scrollBounceBehavior(.basedOnSize)
                .softScrollEdges()
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
                else if value == "house" { HouseModeView().environmentObject(appState) }
                else if value == "doorbell_talk" { DoorbellSoundboardView() }
            }
        }
    }

    // MARK: - House Mode

    /// Headline control: current arm stage + a tap into the full arm/disarm screen. Mirrors Alarmo
    /// via the relay, so it also shows what a partner set.
    private var houseModeCard: some View {
        let opt = HouseModeOption.forKey(appState.houseMode)
        let unknown = appState.houseMode.isEmpty
        return NavigationLink(value: "house") {
            GlassCard {
                HStack(spacing: GlassTheme.Space.m) {
                    ZStack {
                        Circle().fill((unknown ? GlassTheme.accent : opt.color).opacity(0.18))
                            .frame(width: 46, height: 46)
                        Image(systemName: unknown ? "shield.lefthalf.filled" : opt.icon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(unknown ? GlassTheme.accent : opt.color)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("House Mode")
                            .font(.headline)
                            .foregroundStyle(GlassTheme.primary)
                        Text(unknown ? "Tap to arm or disarm" : opt.title)
                            .font(.subheadline)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GlassTheme.tertiary)
                }
                .animation(.easeInOut(duration: 0.25), value: appState.houseMode)
            }
        }
        .buttonStyle(.plain)
        .task { await appState.refreshHouseMode() }
    }

    /// Doorbell talkback: speak at the door with quick replies, on-device TTS, recordings, or MP3s.
    private var doorbellTalkCard: some View {
        NavigationLink(value: "doorbell_talk") {
            GlassCard {
                HStack(spacing: GlassTheme.Space.m) {
                    ZStack {
                        Circle().fill(GlassTheme.accent.opacity(0.18)).frame(width: 46, height: 46)
                        Image(systemName: "megaphone.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(GlassTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Doorbell Talkback")
                            .font(.headline)
                            .foregroundStyle(GlassTheme.primary)
                        Text("Speak at the door · soundboard · MP3")
                            .font(.subheadline)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
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

    // MARK: - Home Network (local ↔ remote fast path)

    private var connectionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                HStack {
                    SectionHeader("Home Network")
                    Spacer(minLength: 0)
                    connectionModeChip
                }

                Text("Add your Frigate's address on your home Wi-Fi. When you're home, ApexSight talks to it directly for the fastest, lowest-latency video — and automatically falls back to your remote address when you're away.")
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: "house.fill")
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.tertiary)
                        .frame(width: 22)
                    TextField("192.168.1.204:5000", text: $localURLDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .focused($localURLFocused)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(GlassTheme.primary)
                        .onSubmit { saveLocalURL() }
                }
                .padding(.horizontal, GlassTheme.Space.m)
                .padding(.vertical, GlassTheme.Space.s + 2)
                .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                        .strokeBorder(GlassTheme.separator, lineWidth: 1)
                )

                if let error = appState.localURLError {
                    Text(error)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(GlassTheme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: GlassTheme.Space.m) {
                    Button {
                        Haptics.tap()
                        saveLocalURL()
                    } label: {
                        Label("Save", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))

                    if appState.session?.localBaseURL != nil {
                        Button(role: .destructive) {
                            Haptics.tap()
                            localURLDraft = ""
                            appState.setLocalURL("")
                        } label: {
                            Label("Remove", systemImage: "xmark.circle")
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.secondary))
                    }
                }
                .padding(.top, GlassTheme.Space.xs)
            }
        }
        // Seed the field from the saved session whenever the card appears or the server changes.
        .onAppear { localURLDraft = appState.session?.localBaseURL?.absoluteString ?? "" }
        .onChange(of: appState.session?.localBaseURL) { _, url in
            if !localURLFocused { localURLDraft = url?.absoluteString ?? "" }
        }
    }

    private var connectionModeChip: some View {
        let onLocal = appState.onLocalNetwork
        return HStack(spacing: 6) {
            Circle()
                .fill(onLocal ? GlassTheme.green : GlassTheme.secondary)
                .frame(width: 7, height: 7)
            Text(appState.connectionModeLabel)
                .font(.caption.weight(.bold))
                .foregroundStyle(onLocal ? GlassTheme.green : GlassTheme.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .liquidGlass(in: Capsule(), fallbackMaterial: .ultraThinMaterial)
    }

    private func saveLocalURL() {
        localURLFocused = false
        appState.setLocalURL(localURLDraft)
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

    // MARK: - Appearance

    // MARK: - Apple Intelligence

    private var spotlightCard: some View {
        GlassCard {
            Toggle(isOn: $spotlightEventsEnabled) {
                HStack(spacing: GlassTheme.Space.m) {
                    iconTile(systemName: "magnifyingglass", tint: GlassTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spotlight Search")
                            .font(.headline)
                            .foregroundStyle(GlassTheme.primary)
                        Text("Find your camera events from the Home Screen search (swipe down). Metadata only — no images are indexed.")
                            .font(.footnote)
                            .foregroundStyle(GlassTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(GlassTheme.accent)
            .sensoryFeedback(.selection, trigger: spotlightEventsEnabled)
            .onChange(of: spotlightEventsEnabled) { _, on in
                if on { SpotlightIndexer.index(appState.events) } else { SpotlightIndexer.clear() }
            }
        }
    }

    private var intelligenceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                Toggle(isOn: $appleIntelligenceEnabled) {
                    HStack(spacing: GlassTheme.Space.m) {
                        iconTile(systemName: "apple.intelligence", tint: GlassTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Intelligence")
                                .font(.headline)
                                .foregroundStyle(GlassTheme.primary)
                            Text("On-device AI for scene analysis, daily summaries and natural-language search. Private — nothing leaves your iPhone.")
                                .font(.footnote)
                                .foregroundStyle(GlassTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(GlassTheme.accent)
                .sensoryFeedback(.selection, trigger: appleIntelligenceEnabled)

                if appleIntelligenceEnabled {
                    Divider().overlay(GlassTheme.separator)
                    NavigationLink {
                        AICamerasSettingsView().environmentObject(appState)
                    } label: {
                        HStack(spacing: GlassTheme.Space.m) {
                            iconTile(systemName: "video.badge.waveform", tint: GlassTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI Cameras")
                                    .font(.headline)
                                    .foregroundStyle(GlassTheme.primary)
                                Text("Choose which cameras run on-device analysis.")
                                    .font(.footnote)
                                    .foregroundStyle(GlassTheme.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(GlassTheme.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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

    // MARK: - Server Tools (config editor + restart)

    private var serverToolsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Server")

                Button {
                    Haptics.tap()
                    showConfigEditor = true
                } label: {
                    settingsRowContent(icon: "curlybraces", title: "Edit config.yml",
                                       subtitle: "Load, edit, validate & save your Frigate config")
                }
                .buttonStyle(.plain)

                Divider().overlay(GlassTheme.separator)

                Button {
                    Haptics.tap()
                    showMyExports = true
                } label: {
                    settingsRowContent(icon: "film.stack", title: "My Exports",
                                       subtitle: "Clips you've exported — share, save, rename, delete")
                }
                .buttonStyle(.plain)

                Divider().overlay(GlassTheme.separator)

                Button {
                    Haptics.tap()
                    showRestartConfirm = true
                } label: {
                    settingsRowContent(icon: "arrow.triangle.2.circlepath", title: "Restart Frigate",
                                       subtitle: "Bounce the Frigate process — cameras briefly drop", tint: GlassTheme.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .fullScreenCover(isPresented: $showConfigEditor) {
            ConfigEditorView().environmentObject(appState)
        }
        .sheet(isPresented: $showMyExports) {
            NavigationStack { MyExportsView().environmentObject(appState) }
        }
        .confirmationDialog("Restart Frigate now?", isPresented: $showRestartConfirm, titleVisibility: .visible) {
            Button("Restart Frigate", role: .destructive) {
                Task {
                    do {
                        try await appState.client?.restart()
                        restartToast = "Restarting Frigate…"
                        Haptics.success()
                    } catch {
                        restartToast = "Restart failed — check the connection"
                        Haptics.warning()   // don't buzz "success" when the restart didn't happen
                    }
                    try? await Task.sleep(nanoseconds: 2_500_000_000); restartToast = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All cameras go offline for a few seconds while Frigate restarts.")
        }
        .overlay(alignment: .bottom) {
            if let restartToast {
                Text(restartToast)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, GlassTheme.Space.l).padding(.vertical, GlassTheme.Space.s)
                    .liquidGlass(in: Capsule(), fallbackMaterial: .ultraThinMaterial)
            }
        }
    }

    /// Shared row content used by the tappable Server Tools buttons (mirrors `settingsRow`).
    private func settingsRowContent(icon: String, title: String, subtitle: String, tint: Color = GlassTheme.accent) -> some View {
        HStack(spacing: GlassTheme.Space.m) {
            iconTile(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(GlassTheme.primary)
                Text(subtitle).font(.footnote).foregroundStyle(GlassTheme.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(GlassTheme.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - About

    /// The app's black box. On by design (see DiagnosticLog) — this exists so "it did something
    /// odd while I was testing" survives long enough to be fixed.
    private var diagnosticsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Diagnostics")

                Toggle(isOn: $diagnosticsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send error log to the relay")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GlassTheme.primary)
                        // Footnote + primary, not caption/tertiary: this describes where data goes,
                        // which is the class of text the accessibility pass says must stay legible.
                        Text("Records errors this app hits and sends them to your own Home Assistant relay, so problems can be looked at later. Never leaves your household, and passwords, tokens and codes are stripped out before anything is written down.")
                            .font(.footnote)
                            .foregroundStyle(GlassTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(GlassTheme.accent)
                .onChange(of: diagnosticsEnabled) { _, on in
                    DiagnosticLog.isEnabled = on
                    if on { DiagnosticLog.shared.info("settings", "diagnostics enabled") }
                }
            }
        }
    }

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

    #if DEBUG
    // MARK: - Developer (DEBUG builds only)

    /// Deterministic triggers for surfaces that otherwise need a real Frigate alert to fire:
    /// the Live Activity / Dynamic Island path and the Apple Watch push. Never compiled into
    /// Release — the whole card is behind `#if DEBUG`.
    private var debugCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Developer")
                Text("Debug builds only — fires the real Live Activity and watch-sync code paths with a synthetic alert.")
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.secondary)

                Button {
                    Haptics.tap()
                    DebugTriggers.fireLiveActivity(camera: debugCamera)
                } label: {
                    Label("Test Live Activity", systemImage: "bell.badge.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))

                Button {
                    Haptics.tap()
                    DebugTriggers.fireWatchPush(camera: debugCamera)
                } label: {
                    Label("Test Watch Push", systemImage: "applewatch.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
            }
        }
    }

    private var debugCamera: String {
        appState.cameras.first?.name ?? "front_door"
    }
    #endif
}
