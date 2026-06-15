import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var path = NavigationPath()

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

                        // Quick nav cards
                        settingsRow(icon: "waveform.path.ecg", title: "System Health", subtitle: "Cameras, detectors, storage", tint: GlassTheme.green) {
                            path.append("system")
                        }
                        settingsRow(icon: "bell.badge.fill", title: "Notifications", subtitle: "Per-camera preferences, quiet hours", tint: GlassTheme.orange) {
                            path.append("notifications")
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { value in
                if value == "system" { SystemHealthView() }
                else if value == "notifications" { NotificationSettingsView() }
                else if value == "servers" { ServerSwitcherView() }
            }
        }
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
