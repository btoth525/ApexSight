import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var path = NavigationPath()
    @AppStorage("colorSchemePreference") private var colorSchemePreference = "dark"
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

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

                        // Quick nav cards
                        settingsRow(icon: "waveform.path.ecg", title: "System Health", subtitle: "Cameras, detectors, storage", tint: GlassTheme.green) {
                            path.append("system")
                        }
                        settingsRow(icon: "bell.badge.fill", title: "Notifications", subtitle: "Per-camera preferences, quiet hours", tint: GlassTheme.orange) {
                            path.append("notifications")
                        }
                        settingsRow(icon: "bolt.horizontal.fill", title: "Instant Push", subtitle: "Optional companion for alerts when closed", tint: GlassTheme.cyan) {
                            path.append("push")
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
            .navigationDestination(for: String.self) { value in
                if value == "system" { SystemHealthView() }
                else if value == "notifications" { NotificationSettingsView(prefsStore: appState.notificationPrefs) }
                else if value == "servers" { ServerSwitcherView() }
                else if value == "push" { PushCompanionSettingsView() }
            }
        }
    }

    private func appearanceOption(label: String, icon: String, value: String) -> some View {
        let selected = colorSchemePreference == value
        return Button {
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
        Button(action: action) {
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
