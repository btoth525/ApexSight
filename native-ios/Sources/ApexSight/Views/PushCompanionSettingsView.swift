import SwiftUI
import UIKit
import UserNotifications

/// Instant-push setup. The relay URL is baked in (RelayConfig.defaultURL), so the
/// user only sees a connection status and their pairing code. Enabling it
/// registers this device for APNs and with the relay; the user pastes the pairing
/// code into the Home Assistant bridge addon. The app is fully functional without
/// this — it adds instant alerts when the app is completely closed.
struct PushCompanionSettingsView: View {
    @State private var pushEnabled = DeviceTokenStore.pushEnabled
    @State private var pairingCode = DeviceTokenStore.ensurePairingCode()
    @State private var token = DeviceTokenStore.deviceTokenHex
    @State private var error = DeviceTokenStore.lastError
    @State private var registerStatus: RegisterStatus = .idle
    @State private var connection: ConnectionState = .checking
    @State private var lastRegisteredToken: String?
    @State private var copiedCode = false
    @State private var showJoinField = false
    @State private var joinCode = ""

    private var relayURL: String { DeviceTokenStore.relayURL }

    private enum RegisterStatus: Equatable {
        case idle, registering, registered, failed(String)
    }

    private enum ConnectionState: Equatable {
        case checking
        case online(apnsConfigured: Bool)
        case offline
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explainerCard
                    toggleCard
                    if pushEnabled {
                        connectionCard
                        pairingCard
                        instructionsCard
                        advancedCard
                    }
                }
                .padding(18)
            }
        }
        .navigationTitle("Instant Push")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task {
            if pushEnabled { await checkHealth() }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            guard pushEnabled else { return }
            token = DeviceTokenStore.deviceTokenHex
            error = DeviceTokenStore.lastError
            // Auto-register once the token arrives (or changes).
            if let token, !token.isEmpty, token != lastRegisteredToken,
               !pairingCode.isEmpty, registerStatus != .registering {
                Task { await registerWithRelay() }
            }
        }
        .onReceive(Timer.publish(every: 6, on: .main, in: .common).autoconnect()) { _ in
            if pushEnabled { Task { await checkHealth() } }
        }
    }

    // MARK: - Cards

    private var explainerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Instant alerts, app closed", systemImage: "bolt.horizontal.fill")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text("Turn this on, then paste the pairing code below into the ApexSight Push Bridge add-on in Home Assistant. Frigate alerts then arrive instantly even when ApexSight is fully closed.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GlassTheme.secondary)
                Text("Everything else in the app works without this.")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(GlassTheme.tertiary)
            }
        }
    }

    private var toggleCard: some View {
        GlassCard {
            Toggle(isOn: Binding(
                get: { pushEnabled },
                set: { newValue in
                    pushEnabled = newValue
                    DeviceTokenStore.pushEnabled = newValue
                    if newValue {
                        Task { await enablePush(); await checkHealth() }
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable instant push")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Text("Registers this device for APNs")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(GlassTheme.secondary)
                }
            }
            .tint(GlassTheme.cyan)
        }
    }

    /// The single green/red status the user asked for.
    private var connectionCard: some View {
        let s = status
        return GlassCard {
            HStack(spacing: 12) {
                Circle()
                    .fill(s.color)
                    .frame(width: 12, height: 12)
                    .shadow(color: s.color.opacity(0.7), radius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Text(s.subtitle)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
                }
                Spacer()
                if s.spinning {
                    ProgressView().tint(GlassTheme.cyan)
                } else if s.showRetry {
                    Button("Retry") {
                        Task { await checkHealth(); await registerWithRelay() }
                    }
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(GlassTheme.cyan)
                }
            }
        }
    }

    private var pairingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pairing Code")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                Text(pairingCode)
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundStyle(GlassTheme.cyan)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(GlassTheme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = pairingCode
                        copiedCode = true
                    } label: {
                        Label(copiedCode ? "Copied" : "Copy", systemImage: copiedCode ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(tint: copiedCode ? GlassTheme.green : GlassTheme.blue))

                    Button {
                        showJoinField.toggle()
                    } label: {
                        Label("Join household", systemImage: "person.2.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.purple))
                }

                if showJoinField {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use another device's code so both get the same alerts:")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                        HStack(spacing: 8) {
                            TextField("APEX-XXXX-XXXX", text: $joinCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                                .foregroundStyle(GlassTheme.primary)
                                .padding(10)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Button("Set") {
                                let code = joinCode.uppercased().trimmingCharacters(in: .whitespaces)
                                guard !code.isEmpty else { return }
                                pairingCode = code
                                DeviceTokenStore.pairingCode = code
                                DeviceTokenStore.pairingOverridden = true
                                lastRegisteredToken = nil   // force re-register under new code
                                showJoinField = false
                                joinCode = ""
                                Task { await registerWithRelay() }
                            }
                            .buttonStyle(PillButtonStyle(tint: GlassTheme.cyan))
                        }
                    }
                }
            }
        }
    }

    private var usingSharedDefault: Bool {
        !RelayConfig.defaultPairingCode.isEmpty && !DeviceTokenStore.pairingOverridden
    }

    @ViewBuilder
    private var instructionsCard: some View {
        if usingSharedDefault {
            GlassCard {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(GlassTheme.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paired automatically")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(GlassTheme.primary)
                        Text("You're on the shared household — alerts arrive whenever this is on. Nothing to set up.")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
            }
        } else {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next: Home Assistant")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    stepRow(1, "Install the “ApexSight Push Bridge” add-on.")
                    stepRow(2, "Paste this pairing code into its settings.")
                    stepRow(3, "Set your Frigate URL so alerts include a snapshot.")
                }
            }
        }
    }

    private var advancedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Details (advanced)")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(GlassTheme.secondary)
                Text("Relay: \(relayURL)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GlassTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let token, !token.isEmpty {
                    Text("Token: \(token)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(GlassTheme.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else if let error {
                    Text(error)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.orange)
                }
            }
        }
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(GlassTheme.cyan, in: Circle())
            Text(text)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    // MARK: - Status derivation

    private var status: (color: Color, title: String, subtitle: String, spinning: Bool, showRetry: Bool) {
        switch connection {
        case .checking:
            return (GlassTheme.tertiary, "Checking…", "Contacting the relay", true, false)
        case .offline:
            return (GlassTheme.red, "Disconnected", "Relay unreachable — check your connection", false, true)
        case let .online(apnsConfigured):
            if !apnsConfigured {
                return (GlassTheme.orange, "Relay online", "APNs key not uploaded on the relay yet", false, true)
            }
            switch registerStatus {
            case .registered:
                return (GlassTheme.green, "Connected", "Ready — paste the code into Home Assistant", false, false)
            case .registering:
                return (GlassTheme.orange, "Connecting…", "Registering this device", true, false)
            case let .failed(message):
                return (GlassTheme.red, "Not registered", message, false, true)
            case .idle:
                return (GlassTheme.orange, "Almost there", "Waiting for the APNs token", true, false)
            }
        }
    }

    // MARK: - Actions

    private func enablePush() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func checkHealth() async {
        if case .checking = connection {} else if connection == .offline { connection = .checking }
        let health = await RelayClient.health(relayURL: relayURL)
        if let health {
            connection = .online(apnsConfigured: health.apns_configured ?? false)
        } else {
            connection = .offline
        }
    }

    private func registerWithRelay() async {
        guard let token = DeviceTokenStore.deviceTokenHex, !token.isEmpty else { return }
        registerStatus = .registering
        do {
            try await RelayClient.register(
                relayURL: relayURL,
                deviceToken: token,
                pairingCode: pairingCode,
                environment: APNSEnvironment.current
            )
            lastRegisteredToken = token
            registerStatus = .registered
        } catch {
            registerStatus = .failed(error.localizedDescription)
        }
    }
}
