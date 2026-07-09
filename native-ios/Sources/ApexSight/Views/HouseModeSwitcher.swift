import SwiftUI

/// The house-mode control that sits at the top of the camera wall — a glass segmented switcher
/// (Home · Night · Away) with the active mode glowing in its color and an animated selection that
/// slides between segments. Tapping a mode arms/disarms right from the wall: arming asks a quick
/// confirm, disarming asks Face ID (and, first time only, hands off to the full screen to capture
/// the alarm code). The "set by" name shows only when SOMEONE ELSE set it — never your own phone.
struct HouseModeSwitcher: View {
    @EnvironmentObject private var appState: AppState
    /// Called when the flow needs the full House Mode screen (first-time disarm code entry / details).
    var onOpenDetail: () -> Void

    @State private var confirmArm: HouseModeOption?
    @State private var errorText: String?
    @Namespace private var pill
    private let keychain = KeychainStore()

    /// Who set the mode, but only if it wasn't this phone (showing your own name is just noise).
    private var setByOther: String? {
        let mine = DeviceTokenStore.deviceName.trimmingCharacters(in: .whitespaces)
        let by = appState.houseModeArmedBy.trimmingCharacters(in: .whitespaces)
        guard !by.isEmpty, by.caseInsensitiveCompare(mine) != .orderedSame else { return nil }
        return by
    }

    var body: some View {
        if !appState.houseMode.isEmpty {
            VStack(spacing: GlassTheme.Space.s) {
                header
                switcher
            }
            .confirmationDialog(
                confirmArm.map { "Arm \($0.title)?" } ?? "",
                isPresented: Binding(get: { confirmArm != nil }, set: { if !$0 { confirmArm = nil } }),
                titleVisibility: .visible
            ) {
                if let option = confirmArm {
                    Button("Arm \(option.title)") { submit(option.key) }
                    Button("Cancel", role: .cancel) {}
                }
            } message: { Text(confirmArm?.armConfirmation ?? "") }
            .alert("Couldn't change mode", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private var header: some View {
        HStack(spacing: GlassTheme.Space.s) {
            Text("HOUSE")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(GlassTheme.tertiary)
            if let who = setByOther {
                Text("· set by \(who)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(GlassTheme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if appState.houseModeBusy {
                ProgressView().controlSize(.mini).tint(GlassTheme.accent)
            }
            Button {
                Haptics.tap()
                onOpenDetail()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GlassTheme.secondary)
                    .hitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("House mode details")
        }
        .padding(.horizontal, 4)
    }

    private var switcher: some View {
        HStack(spacing: 4) {
            ForEach(HouseModeOption.all) { segment($0) }
        }
        .padding(4)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous)
            .strokeBorder(GlassTheme.separator, lineWidth: 1))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.houseMode)
    }

    private func segment(_ option: HouseModeOption) -> some View {
        let active = option.key == appState.houseMode
        return Button {
            tap(option)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: option.icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(option.title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(active ? Color.white : GlassTheme.secondary)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.tile - 4, style: .continuous)
                        .fill(
                            LinearGradient(colors: [option.color, option.color.opacity(0.72)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .shadow(color: option.color.opacity(0.45), radius: 8, y: 2)
                        .matchedGeometryEffect(id: "activePill", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(appState.houseModeBusy)
        .accessibilityLabel("\(option.title)\(active ? ", current" : "")")
    }

    // MARK: - Actions

    private func tap(_ option: HouseModeOption) {
        guard option.key != appState.houseMode, !appState.houseModeBusy else { return }
        Haptics.tap()
        if option.key == "home" {
            // Disarm — Face ID, then the stored code; first time (no code yet) → full screen.
            Task {
                let ok = await BiometricLock.authenticate(reason: "Disarm the house")
                guard ok else { return }
                if let code = keychain.alarmCode, !code.isEmpty {
                    submit("home", code: code)
                } else {
                    onOpenDetail()
                }
            }
        } else {
            confirmArm = option   // arm → quick confirm to avoid a mis-tap
        }
    }

    private func submit(_ key: String, code: String = "") {
        Task {
            do {
                let converged = try await appState.requestHouseMode(key, code: code)
                if !converged {
                    switch key {
                    case "home": errorText = "That code didn't disarm the house. Open House Mode to re-enter it."
                    case "night": errorText = "Night mode isn't set up in Alarmo yet. Enable it in Home Assistant → Alarmo → Arm modes."
                    default: errorText = "That didn't take — the house may not have changed. Try again."
                    }
                }
            } catch {
                errorText = "The relay couldn't be reached. Try again."
            }
        }
    }
}
