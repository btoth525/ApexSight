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
    @State private var tokenPollingTask: Task<Void, Never>?
    @State private var healthPollingTask: Task<Void, Never>?

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
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    explainerCard
                    connectionCard
                    testCard
                    advancedCard
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle("Instant Push")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .task {
            DeviceTokenStore.pushEnabled = true
            await enablePush()
            await checkHealth()
            tokenPollingTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { break }
                    token = DeviceTokenStore.deviceTokenHex
                    if let token, !token.isEmpty, token != lastRegisteredToken,
                       !pairingCode.isEmpty, registerStatus != .registering {
                        await registerWithRelay()
                    }
                }
            }
            healthPollingTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { break }
                    await checkHealth()
                }
            }
        }
        .onDisappear {
            tokenPollingTask?.cancel()
            healthPollingTask?.cancel()
        }
    }

    // MARK: - Cards

    private var explainerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                Label("Instant alerts, app closed", systemImage: "bolt.horizontal.fill")
                    .font(.headline)
                    .foregroundStyle(GlassTheme.primary)
                Text("Always on. This device is set up for push automatically — the status below shows whether it's connected.")
                    .font(.subheadline)
                    .foregroundStyle(GlassTheme.secondary)
            }
        }
    }

    /// The single green/red status.
    private var connectionCard: some View {
        let s = status
        return GlassCard {
            HStack(spacing: GlassTheme.Space.m) {
                Circle()
                    .fill(s.color)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                    Text(s.title)
                        .font(.headline)
                        .foregroundStyle(GlassTheme.primary)
                    Text(s.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                }
                Spacer()
                if s.spinning {
                    ProgressView().tint(GlassTheme.accent)
                } else if s.showRetry {
                    Button("Retry") {
                        Haptics.tap()
                        Task { await enablePush(); await checkHealth(); await registerWithRelay() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.accent)
                    .accessibilityLabel("Retry push connection")
                }
            }
            .animation(.easeInOut(duration: 0.25), value: s.title)
        }
    }

    private var testCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                Button {
                    Task { await sendTest() }
                } label: {
                    HStack(spacing: GlassTheme.Space.s) {
                        if testSending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text(testSending ? "Sending…" : "Send Test Push")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                .disabled(testSending || !isConnected)

                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(testResult.hasPrefix("Sent") ? GlassTheme.green : GlassTheme.orange)
                } else {
                    Text("Sends a real push to this phone through the relay. Lock your screen to see it land.")
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: testResult)
        }
    }

    private var advancedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Details", subtitle: "Advanced")

                HStack(spacing: GlassTheme.Space.s) {
                    Text("Pairing: \(pairingCode)")
                        .font(.footnote.weight(.semibold))
                        .monospaced()
                        .foregroundStyle(GlassTheme.primary)
                    Button {
                        UIPasteboard.general.string = pairingCode
                        Haptics.success()
                        copiedCode = true
                        // Revert the checkmark so the button reads as "copy" again next time.
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copiedCode = false
                        }
                    } label: {
                        Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(copiedCode ? GlassTheme.green : GlassTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copiedCode ? "Pairing code copied" : "Copy pairing code")
                    Spacer()
                    Button(showJoinField ? "Cancel" : "Use private code") { showJoinField.toggle() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                }

                if showJoinField {
                    HStack(spacing: GlassTheme.Space.s) {
                        TextField("APEX-XXXX-XXXX", text: $joinCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.subheadline.weight(.semibold))
                            .monospaced()
                            .foregroundStyle(GlassTheme.primary)
                            .padding(GlassTheme.Space.m)
                            .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
                            .cardStroke(GlassTheme.Radius.chip)
                        Button("Set") {
                            let code = joinCode.uppercased().trimmingCharacters(in: .whitespaces)
                            guard !code.isEmpty else { return }
                            Haptics.tap()
                            pairingCode = code
                            DeviceTokenStore.pairingCode = code
                            DeviceTokenStore.pairingOverridden = true
                            lastRegisteredToken = nil
                            showJoinField = false
                            joinCode = ""
                            Task { await registerWithRelay() }
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                        .disabled(joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Text("Relay: \(relayURL)")
                    .font(.caption)
                    .monospaced()
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
            return (GlassTheme.offline, "Checking…", "Contacting the relay", true, false)
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
            Haptics.success()
        } catch {
            testResult = error.localizedDescription
            Haptics.error()
        }
    }
}
