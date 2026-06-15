import SwiftUI
import UIKit
import UserNotifications

/// Optional instant-push setup. The app works fully without this; enabling it
/// registers for APNs and shows the device token to paste into a companion
/// notifier (a separate service that subscribes to Frigate and sends push).
struct PushCompanionSettingsView: View {
    @State private var pushEnabled = DeviceTokenStore.pushEnabled
    @State private var token = DeviceTokenStore.deviceTokenHex
    @State private var error = DeviceTokenStore.lastError
    @State private var copied = false

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explainerCard
                    toggleCard
                    if pushEnabled { tokenCard }
                }
                .padding(18)
            }
        }
        .navigationTitle("Instant Push")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            // Token arrives asynchronously after registration.
            token = DeviceTokenStore.deviceTokenHex
            error = DeviceTokenStore.lastError
        }
    }

    private var explainerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("How it works", systemImage: "bolt.horizontal.fill")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text("ApexSight already alerts you in real time while open, and checks for new alerts in the background. For instant alerts when the app is fully closed, run the optional companion notifier and paste the token below into its config.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GlassTheme.secondary)
                Text("This is optional — everything else works without it. Requires a paid Apple Developer account and a real device.")
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

    private var tokenCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Device Token")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                if let token, !token.isEmpty {
                    Text(token)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(GlassTheme.cyan)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        UIPasteboard.general.string = token
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Token", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(tint: copied ? GlassTheme.green : GlassTheme.blue))
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(GlassTheme.orange)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().tint(GlassTheme.cyan)
                        Text("Waiting for APNs registration…")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
            }
        }
    }

    private func enablePush() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
}
