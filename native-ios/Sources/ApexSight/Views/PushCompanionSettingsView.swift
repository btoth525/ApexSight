import SwiftUI
import UIKit
import UserNotifications

/// Instant push — always on. The relay URL and (for shared cameras) the pairing
/// code are baked in, so there's nothing to configure: this device registers for
/// APNs and with the relay automatically on appear. The screen shows a single
/// connection status (green/red) and a Test button to verify the pipeline.
struct PushCompanionSettingsView: View {
    @State private var pairingCode = DeviceTokenStore.ensurePairingCode()
    @State private var token = DeviceTokenStore.deviceTokenHex
    @State private var registerStatus: RegisterStatus = .idle
    @State private var connection: ConnectionState = .checking
    @State private var lastRegisteredToken: String?
    @State private var permissionDenied = false
    @State private var testResult: String?
    @State private var testSending = false
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
                    connectionCard
                    testCard
                    advancedCard
                }
                .padding(18)
            }
        }
        .navigationTitle("Instant Push")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task {
            DeviceTokenStore.pushEnabled = true   // always on
            await enablePush()
            await checkHealth()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            token = DeviceTokenStore.deviceTokenHex
            if let token, !token.isEmpty, token != lastRegisteredToken,
               !pairingCode.isEmpty, registerStatus != .registering {
                Task { await registerWithRelay() }
            }
        }
        .onReceive(Timer.publish(every: 6, on: .main, in: .common).autoconnect()) { _ in
            Task { await checkHealth() }
        }
    }

    // MARK: - Cards

    private var explainerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Instant alerts, app closed", systemImage: "bolt.horizontal.fill")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text("Always on. This device is set up for push automatically — the status below shows whether it's connected.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GlassTheme.secondary)
            }
        }
    }

    /// The single green/red status.
    private var connectionCard: some View {
        let s = status
        return GlassCard {
            HStack(spacing: 12) {
                Circle()
                    .fill(s.color)
                    .frame(width: 14, height: 14)
                    .shadow(color: s.color.opacity(0.7), radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title)
                        .font(.system(size: 16, weight: .black))
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
                        Task { await enablePush(); await checkHealth(); await registerWithRelay() }
                    }
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(GlassTheme.cyan)
                }
            }
        }
    }

    private var testCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    Task { await sendTest() }
                } label: {
                    HStack {
                        if testSending {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text(testSending ? "Sending…" : "Send Test Push")
                            .font(.system(size: 15, weight: .black))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.cyan))
                .disabled(testSending || !isConnected)

                if let testResult {
                    Text(testResult)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(testResult.hasPrefix("Sent") ? GlassTheme.green : GlassTheme.orange)
                } else {
                    Text("Sends a real push to this phone through the relay. Lock your screen to see it land.")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
                }
            }
        }
    }

    private var advancedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Details (advanced)")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(GlassTheme.secondary)

                HStack(spacing: 8) {
                    Text("Pairing: \(pairingCode)")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(GlassTheme.cyan)
                    Button {
                        UIPasteboard.general.string = pairingCode
                        copiedCode = true
                    } label: {
                        Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(copiedCode ? GlassTheme.green : GlassTheme.blue)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(showJoinField ? "Cancel" : "Use private code") { showJoinField.toggle() }
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(GlassTheme.purple)
                }

                if showJoinField {
                    HStack(spacing: 8) {
                        TextField("APEX-XXXX-XXXX", text: $joinCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .foregroundStyle(GlassTheme.primary)
                            .padding(9)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button("Set") {
                            let code = joinCode.uppercased().trimmingCharacters(in: .whitespaces)
                            guard !code.isEmpty else { return }
                            pairingCode = code
                            DeviceTokenStore.pairingCode = code
                            DeviceTokenStore.pairingOverridden = true
                            lastRegisteredToken = nil
                            showJoinField = false
                            joinCode = ""
                            Task { await registerWithRelay() }
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.cyan))
                    }
                }

                Text("Relay: \(relayURL)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GlassTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Status derivation

    private var isConnected: Bool {
        if case .online(true) = connection, registerStatus == .registered { return true }
        return false
    }

    private var status: (color: Color, title: String, subtitle: String, spinning: Bool, showRetry: Bool) {
        if permissionDenied {
            return (GlassTheme.red, "Notifications off", "Turn on notifications for ApexSight in iOS Settings", false, true)
        }
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
                return (GlassTheme.green, "Connected", "Push is active — you'll get alerts with the app closed", false, false)
            case .registering:
                return (GlassTheme.orange, "Connecting…", "Registering this device", true, false)
            case let .failed(message):
                return (GlassTheme.red, "Not connected", message, false, true)
            case .idle:
                return (GlassTheme.orange, "Almost there", "Waiting for the APNs token", true, false)
            }
        }
    }

    // MARK: - Actions

    private func enablePush() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        permissionDenied = !granted
        if granted {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    private func checkHealth() async {
        if connection == .offline { connection = .checking }
        let health = await RelayClient.health(relayURL: relayURL)
        connection = health.map { .online(apnsConfigured: $0.apns_configured ?? false) } ?? .offline
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

    private func sendTest() async {
        guard let token = DeviceTokenStore.deviceTokenHex, !token.isEmpty else {
            testResult = "No device token yet — give it a moment."
            return
        }
        testSending = true
        defer { testSending = false }
        do {
            try await RelayClient.sendTest(relayURL: relayURL, deviceToken: token, environment: APNSEnvironment.current)
            testResult = "Sent ✓ — lock your phone to see it land."
        } catch {
            testResult = error.localizedDescription
        }
    }
}
