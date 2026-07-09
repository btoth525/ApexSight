import SwiftUI

/// House Mode — arm/disarm the home right from the app. The app is a *view + requester*: it never
/// owns the state. A tap routes through the relay → Home Assistant → Alarmo; Alarmo's resulting
/// state flows back so this screen (and a partner's phone) reflect the truth within one poll.
///
/// Security posture (deliberate, see the relay's /v1/set-mode):
///   • Arming (Away / Night) *raises* security — one tap, rides the pairing code.
///   • Disarming (Home) *lowers* it — gated by Face ID here AND the Alarmo code server-side, so a
///     found phone or a leaked pairing code alone can never drop the alarm.
struct HouseModeView: View {
    @EnvironmentObject private var appState: AppState

    @State private var showCodeEntry = false
    @State private var pendingCodeEntry = ""
    @State private var confirmArm: HouseModeOption?
    @State private var errorText: String?
    @State private var showChangeCode = false

    private let keychain = KeychainStore()

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    statusCard
                    ForEach(HouseModeOption.all) { option in
                        modeButton(option)
                    }
                    footer
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle("House Mode")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task { await appState.refreshHouseMode() }
        .confirmationDialog(
            confirmArm.map { "Arm \($0.title)?" } ?? "",
            isPresented: Binding(get: { confirmArm != nil }, set: { if !$0 { confirmArm = nil } }),
            titleVisibility: .visible
        ) {
            if let option = confirmArm {
                Button("Arm \(option.title)") { submit(option.key) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text(confirmArm?.armConfirmation ?? "")
        }
        .sheet(isPresented: $showCodeEntry) { codeEntrySheet }
        .sheet(isPresented: $showChangeCode) { codeEntrySheet }
        .alert("Couldn't change mode", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - Cards

    private var current: HouseModeOption { HouseModeOption.forKey(appState.houseMode) }

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                HStack(spacing: GlassTheme.Space.m) {
                    ZStack {
                        Circle().fill(current.color.opacity(0.18)).frame(width: 54, height: 54)
                        Image(systemName: current.icon)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(current.color)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.houseMode.isEmpty ? "Unknown" : current.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(GlassTheme.primary)
                        Text(current.statusSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                    Spacer()
                    if appState.houseModeBusy { ProgressView().tint(GlassTheme.accent) }
                }
                if !appState.houseModeArmedBy.isEmpty {
                    Label("Set by \(appState.houseModeArmedBy)", systemImage: "person.fill")
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: appState.houseMode)
        }
    }

    private func modeButton(_ option: HouseModeOption) -> some View {
        let isCurrent = option.key == appState.houseMode
        let disabled = !option.available || appState.houseModeBusy || isCurrent
        return Button {
            Haptics.tap()
            tap(option)
        } label: {
            HStack(spacing: GlassTheme.Space.m) {
                Image(systemName: option.icon)
                    .font(.title3)
                    .foregroundStyle(option.available ? option.color : GlassTheme.tertiary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.headline)
                        .foregroundStyle(option.available ? GlassTheme.primary : GlassTheme.secondary)
                    Text(option.available ? option.subtitle : option.unavailableNote)
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(option.color)
                } else if option.key == "home" && option.available {
                    Image(systemName: BiometricLock.symbolName).foregroundStyle(GlassTheme.tertiary)
                }
            }
            .padding(GlassTheme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
            .cardStroke(GlassTheme.Radius.card)
            .opacity(disabled && !isCurrent ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
            if keychain.alarmCode?.isEmpty == false {
                Button {
                    Haptics.tap()
                    pendingCodeEntry = ""
                    showChangeCode = true
                } label: {
                    Label("Change alarm code", systemImage: "key.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                }
                .buttonStyle(.plain)
            }
            Text("Arming rides your pairing. Disarming asks for \(BiometricLock.label) and your alarm code — the code is checked by Home Assistant, so it never leaves your control.")
                .font(.caption)
                .foregroundStyle(GlassTheme.tertiary)
        }
        .padding(.top, GlassTheme.Space.s)
    }

    private var codeEntrySheet: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    Text("Enter your Alarmo code so ApexSight can disarm the house. It's stored only in this phone's Keychain and sent only after \(BiometricLock.label).")
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                    SecureField("Alarm code", text: $pendingCodeEntry)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title3.weight(.semibold))
                        .monospaced()
                        .foregroundStyle(GlassTheme.primary)
                        .padding(GlassTheme.Space.m)
                        .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
                        .cardStroke(GlassTheme.Radius.chip)
                    Button("Save") {
                        let code = pendingCodeEntry.trimmingCharacters(in: .whitespaces)
                        guard !code.isEmpty else { return }
                        keychain.saveAlarmCode(code)
                        Haptics.success()
                        let wasDisarm = showCodeEntry
                        showCodeEntry = false
                        showChangeCode = false
                        // If this entry was to unblock a disarm, proceed with it now.
                        if wasDisarm { submit("home", code: code) }
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                    .disabled(pendingCodeEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
                .padding(GlassTheme.Space.l)
            }
            .navigationTitle("Alarm Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCodeEntry = false; showChangeCode = false }
                }
            }
        }
    }

    // MARK: - Actions

    private func tap(_ option: HouseModeOption) {
        guard option.available else { return }
        if option.key == "home" {
            // Disarm — Face ID, then the alarm code (server-side validated by Alarmo).
            Task {
                let ok = await BiometricLock.authenticate(reason: "Disarm the house")
                guard ok else { return }
                if let code = keychain.alarmCode, !code.isEmpty {
                    submit("home", code: code)
                } else {
                    pendingCodeEntry = ""
                    showCodeEntry = true
                }
            }
        } else {
            // Arm — confirm to avoid an accidental arm, then request (no code needed).
            confirmArm = option
        }
    }

    private func submit(_ key: String, code: String = "") {
        Task {
            do {
                // Waits for the house to actually reach `key` (up to ~12s). A wrong disarm code is
                // rejected by Alarmo → never converges → we surface it; a correct one lands quickly.
                let converged = try await appState.requestHouseMode(key, code: code)
                if !converged {
                    errorText = key == "home"
                        ? "Disarm didn't take — check your alarm code and try again."
                        : "That didn't take — the house may not have changed. Try again."
                }
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? "The relay couldn't be reached. Try again."
            }
        }
    }
}

/// A selectable house mode. `available` is false for Night until the user enables `armed_night`
/// in Alarmo — shipping a Night button that only moved the camera filter would make the app lie
/// about the physical alarm state.
struct HouseModeOption: Identifiable {
    let key: String        // "home" | "away" | "night" — matches the relay
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let available: Bool

    var id: String { key }

    var unavailableNote: String { "Enable Night mode in Alarmo to use this." }
    var armConfirmation: String {
        key == "away"
            ? "Everyone should be leaving — the house arms after the exit delay and every camera will alert."
            : "Arms the perimeter for overnight. Inside cameras stay quiet."
    }
    var statusSubtitle: String {
        switch key {
        case "home": return "Disarmed — only the front cameras alert."
        case "away": return "Armed away — every camera alerts."
        case "night": return "Armed for the night — perimeter alerts."
        default: return "Waiting for Home Assistant…"
        }
    }

    static let all: [HouseModeOption] = [
        HouseModeOption(key: "home", title: "Home", subtitle: "Disarm — you're here. Only front cameras alert.",
                        icon: "house.fill", color: GlassTheme.green, available: true),
        HouseModeOption(key: "night", title: "Night", subtitle: "Arm the perimeter overnight.",
                        icon: "moon.stars.fill", color: .indigo, available: false),
        HouseModeOption(key: "away", title: "Away", subtitle: "Arm everything — every camera alerts.",
                        icon: "shield.lefthalf.filled", color: GlassTheme.accent, available: true),
    ]

    static func forKey(_ key: String) -> HouseModeOption {
        all.first { $0.key == key } ?? HouseModeOption(
            key: key, title: "Unknown", subtitle: "", icon: "questionmark.circle",
            color: GlassTheme.secondary, available: false
        )
    }
}
