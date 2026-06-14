import SwiftUI

struct SystemHealthView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("System Health")
                            .font(.system(size: 28, weight: .900, design: .rounded))
                            .foregroundStyle(GlassTheme.primary)

                        Text("Native Frigate diagnostics")
                            .font(.system(size: 14, weight: .800))
                            .foregroundStyle(GlassTheme.secondary)

                        Button {
                            Task { await appState.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.green))

                        Button {
                            Task { await appState.refreshCapabilityDiagnostics() }
                        } label: {
                            Label("Run Diagnostics", systemImage: "stethoscope")
                        }
                        .buttonStyle(PillButtonStyle(tint: GlassTheme.blue))
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Overview")
                            .font(.system(size: 21, weight: .900))
                            .foregroundStyle(GlassTheme.primary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            metric("Cameras", value: "\(appState.stats?.cameras?.count ?? appState.cameras.count)")
                            metric("Detectors", value: "\(appState.stats?.detectors?.count ?? 0)")
                            metric("Events", value: "\(appState.events.count)")
                            metric("Status", value: appState.errorMessage == nil ? "Healthy" : "Needs attention")
                        }
                    }
                }

                if let detectors = appState.stats?.detectors, !detectors.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Detectors")
                                .font(.system(size: 21, weight: .900))
                                .foregroundStyle(GlassTheme.primary)
                            ForEach(detectors.sorted(by: { $0.key < $1.key }), id: \.key) { name, detector in
                                infoRow(
                                    icon: "bolt.fill",
                                    title: titleize(name),
                                    subtitle: "Inference \(format(detector.inferenceSpeed, suffix: "ms")) - PID \(detector.pid.map(String.init) ?? "n/a")"
                                )
                            }
                        }
                    }
                }

                if let cameras = appState.stats?.cameras, !cameras.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Camera Performance")
                                .font(.system(size: 21, weight: .900))
                                .foregroundStyle(GlassTheme.primary)
                            ForEach(cameras.sorted(by: { $0.key < $1.key }), id: \.key) { name, camera in
                                infoRow(
                                    icon: "camera.fill",
                                    title: titleize(name),
                                    subtitle: "Camera \(format(camera.cameraFps, suffix: " fps")) - Detect \(format(camera.detectionFps, suffix: " fps"))"
                                )
                            }
                        }
                    }
                }

                if !appState.recentLogs.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recent Logs")
                                .font(.system(size: 21, weight: .900))
                                .foregroundStyle(GlassTheme.primary)

                            ForEach(appState.recentLogs.suffix(10), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 11, weight: .600, design: .monospaced))
                                    .foregroundStyle(GlassTheme.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .900))
                .foregroundStyle(GlassTheme.secondary)
            Text(value)
                .font(.system(size: 15, weight: .900))
                .foregroundStyle(GlassTheme.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func infoRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .900))
                .foregroundStyle(GlassTheme.green)
                .frame(width: 36, height: 36)
                .background(GlassTheme.green.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .900))
                    .foregroundStyle(GlassTheme.primary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .700))
                    .foregroundStyle(GlassTheme.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func format(_ value: Double?, suffix: String) -> String {
        guard let value else { return "n/a" }
        return "\(String(format: value >= 10 ? "%.0f" : "%.1f", value))\(suffix)"
    }
}
