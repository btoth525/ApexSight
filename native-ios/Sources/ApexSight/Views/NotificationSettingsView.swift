import SwiftUI

struct NotificationSettingsView: View {
    @State private var status = NotificationStatus(isAuthorized: false, description: "Checking")
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Notifications")
                            .font(.system(size: 28, weight: .900, design: .rounded))
                            .foregroundStyle(GlassTheme.primary)

                        Text("Rich Frigate alerts should be fast, clear, and friendly.")
                            .font(.system(size: 14, weight: .800))
                            .foregroundStyle(GlassTheme.secondary)

                        HStack {
                            Label(status.description, systemImage: status.isAuthorized ? "bell.badge.fill" : "bell.slash.fill")
                                .font(.system(size: 15, weight: .900))
                                .foregroundStyle(status.isAuthorized ? GlassTheme.green : GlassTheme.orange)
                            Spacer()
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Preview")
                            .font(.system(size: 21, weight: .900))
                            .foregroundStyle(GlassTheme.primary)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("🧍 Person detected")
                                .font(.system(size: 17, weight: .900))
                                .foregroundStyle(GlassTheme.primary)
                            Text("Front Porch • 94% confidence • Zone: Walkway")
                                .font(.system(size: 13, weight: .700))
                                .foregroundStyle(GlassTheme.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button {
                            Task { await requestPermission() }
                        } label: {
                            Label("Allow Notifications", systemImage: "checkmark.shield.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.blue))
                        .disabled(isWorking)

                        Button {
                            Task { await sendTest() }
                        } label: {
                            Label("Send Test Alert", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.green))
                        .disabled(isWorking || !status.isAuthorized)

                        if let message {
                            Text(message)
                                .font(.system(size: 13, weight: .800))
                                .foregroundStyle(GlassTheme.secondary)
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Next")
                            .font(.system(size: 21, weight: .900))
                            .foregroundStyle(GlassTheme.primary)
                        bullet("Per-camera, per-object, per-zone schedules")
                        bullet("Notification Service Extension for snapshot attachments")
                        bullet("Snooze and open-review actions")
                        bullet("Critical alerts only after explicit opt-in")
                    }
                }
            }
            .padding(18)
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStatus() }
    }

    private func refreshStatus() async {
        status = await NativeNotificationManager.status()
    }

    private func requestPermission() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await NativeNotificationManager.requestPermission()
            await refreshStatus()
            message = "Notifications are ready."
        } catch {
            message = error.localizedDescription
        }
    }

    private func sendTest() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await NativeNotificationManager.sendTestNotification()
            message = "Test alert sent."
        } catch {
            message = error.localizedDescription
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(GlassTheme.green)
            Text(text)
                .font(.system(size: 14, weight: .700))
                .foregroundStyle(GlassTheme.secondary)
        }
    }
}
