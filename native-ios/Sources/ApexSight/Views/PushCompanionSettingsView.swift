import SwiftUI
import UIKit
import UserNotifications

/// Instant-push setup. Enabling it registers this device for APNs and then
/// registers the token with your push relay under a household pairing code. The
/// user pastes that code into the Home Assistant bridge addon — no manual token
/// copying. The app is fully functional without this (real-time while open +
/// background refresh); this adds instant alerts when the app is fully closed.
struct PushCompanionSettingsView: View {
    @State private var pushEnabled = DeviceTokenStore.pushEnabled
    @State private var relayURL = DeviceTokenStore.relayURL
    @State private var pairingCode = DeviceTokenStore.ensurePairingCode()
    @State private var token = DeviceTokenStore.deviceTokenHex
    @State private var error = DeviceTokenStore.lastError
    @State private var registerStatus: RegisterStatus = .idle
    @State private var lastRegisteredToken: String?
    @State private var copiedCode = false
    @State private var showJoinField = false
    @State private var joinCode = ""

    private enum RegisterStatus: Equatable {
        case idle, registering, registered, failed(String)
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explainerCard
                    toggleCard
                    if pushEnabled {
                        relayCard
                        pairingCard
                        statusCard
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
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            token = DeviceTokenStore.deviceTokenHex
            error = DeviceTokenStore.lastError
            // Auto-register once the token arrives (or changes), if enabled + paired.
            if pushEnabled, let token, !token.isEmpty, token != lastRegisteredToken,
               !relayURL.isEmpty, !pairingCode.isEmpty, registerStatus != .registering {
                Task { await registerWithRelay() }
            }
        }
    }

    // MARK: - Cards

    private var explainerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Instant alerts, app closed", systemImage: "bolt.horizontal.fill")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text("This device registers with your push relay and shows a pairing code. Paste that code into the ApexSight Push Bridge add-on in Home Assistant, and Frigate alerts arrive instantly even when ApexSight is fully closed.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GlassTheme.secondary)
                Text("Requires the relay set up with your Apple APNs key. Everything else in the app works without this.")
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
                    if newValue { Task { await enablePush() } }
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

    private var relayCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Relay URL")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                TextField("https://push.yourdomain.com", text: $relayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(GlassTheme.cyan)
                    .padding(12)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onChange(of: relayURL) { _, newValue in
                        DeviceTokenStore.relayURL = newValue
                    }
                Text("Your self-hosted relay (Cloudflare Tunnel URL).")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(GlassTheme.secondary)
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
                                lastRegisteredToken = nil   // force re-register under new code
                                showJoinField = false
                                joinCode = ""
                            }
                            .buttonStyle(PillButtonStyle(tint: GlassTheme.cyan))
                        }
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        GlassCard {
            HStack(spacing: 10) {
                switch registerStatus {
                case .idle:
                    Image(systemName: "circle.dashed").foregroundStyle(GlassTheme.tertiary)
                    Text("Waiting for APNs token…").foregroundStyle(GlassTheme.secondary)
                case .registering:
                    ProgressView().tint(GlassTheme.cyan)
                    Text("Registering with relay…").foregroundStyle(GlassTheme.secondary)
                case .registered:
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(GlassTheme.green)
                    Text("Registered ✓ — paste the code into Home Assistant.").foregroundStyle(GlassTheme.green)
                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GlassTheme.orange)
                    Text(message).foregroundStyle(GlassTheme.orange)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .heavy))
            .overlay(alignment: .bottomTrailing) {
                if case .failed = registerStatus {
                    Button("Retry") { Task { await registerWithRelay() } }
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(GlassTheme.cyan)
                }
            }
        }
    }

    private var instructionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Next: Home Assistant")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                stepRow(1, "Install the “ApexSight Push Bridge” add-on.")
                stepRow(2, "Set the relay URL and paste this pairing code.")
                stepRow(3, "Set your Frigate URL so alerts include a snapshot.")
            }
        }
    }

    private var advancedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Device Token (advanced)")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(GlassTheme.secondary)
                if let token, !token.isEmpty {
                    Text(token)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(GlassTheme.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else if let error {
                    Text(error)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.orange)
                } else {
                    Text("Not registered yet.")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.tertiary)
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

    // MARK: - Actions

    private func enablePush() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func registerWithRelay() async {
        guard let token = DeviceTokenStore.deviceTokenHex, !token.isEmpty else { return }
        let relay = relayURL.trimmingCharacters(in: .whitespaces)
        guard !relay.isEmpty else {
            registerStatus = .failed("Enter your relay URL above.")
            return
        }
        registerStatus = .registering
        do {
            try await RelayClient.register(
                relayURL: relay,
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
