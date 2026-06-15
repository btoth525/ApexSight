import SwiftUI

struct CamerasTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Status strip
                        statusStrip

                        if let error = appState.errorMessage {
                            GlassCard {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 14, weight: .heavy))
                                    .foregroundStyle(GlassTheme.orange)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Live Cameras")
                                            .font(.system(size: 21, weight: .black))
                                            .foregroundStyle(GlassTheme.primary)
                                        Text("\(appState.cameras.count) online")
                                            .font(.system(size: 12, weight: .heavy))
                                            .foregroundStyle(GlassTheme.secondary)
                                    }
                                    Spacer()
                                    if appState.isLoading {
                                        ProgressView().tint(GlassTheme.cyan)
                                    }
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                                    ForEach(appState.cameras) { camera in
                                        CameraCard(camera: camera)
                                    }
                                }
                            }
                        }

                        if !appState.capabilities.isEmpty {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("Camera Capabilities")
                                        .font(.system(size: 21, weight: .black))
                                        .foregroundStyle(GlassTheme.primary)
                                    VStack(spacing: 10) {
                                        ForEach(appState.capabilities) { cap in
                                            CapabilityRow(capability: cap)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .refreshable { await appState.refresh() }
                .task { if appState.cameras.isEmpty { await appState.refresh() } }
            }
            .navigationTitle("Apex Command")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let host = appState.session?.baseURL.host() {
                        Text(host)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(GlassTheme.cyan)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(GlassTheme.cyan.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
    }

    private var statusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                statusMetric(icon: "video.fill", title: "Live", value: "\(appState.cameras.count)", tint: GlassTheme.blue)
                statusMetric(icon: "bell.badge.fill", title: "Review", value: "\(appState.reviews.count)", tint: GlassTheme.orange)
                statusMetric(icon: "tag.fill", title: "Labels", value: "\(appState.labels.count)", tint: GlassTheme.cyan)
                statusMetric(icon: "waveform.path.ecg", title: "Health",
                             value: appState.errorMessage == nil ? "Good" : "Check",
                             tint: appState.errorMessage == nil ? GlassTheme.green : GlassTheme.red)
            }
        }
    }

    private func statusMetric(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(GlassTheme.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
            }
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
