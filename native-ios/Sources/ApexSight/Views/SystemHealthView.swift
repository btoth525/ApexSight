import SwiftUI

struct SystemHealthView: View {
    @EnvironmentObject private var appState: AppState

    /// True before the first successful fetch — drives the loading skeleton rather than
    /// rendering empty "0" metric tiles while the very first stats request is in flight.
    private var isInitialLoad: Bool {
        appState.isLoading && appState.stats == nil && appState.errorMessage == nil
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                SectionHeader("System Health", subtitle: "Native Frigate diagnostics")

                HStack(spacing: GlassTheme.Space.m) {
                    Button {
                        Haptics.tap()
                        Task { await appState.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(appState.isLoading)
                    .accessibilityLabel("Refresh system stats")

                    Button {
                        Haptics.tap()
                        Task { await appState.refreshCapabilityDiagnostics() }
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(appState.isLoading)
                    .accessibilityLabel("Run capability diagnostics")
                }
                .opacity(appState.isLoading ? 0.6 : 1)
                .overlay(alignment: .center) {
                    if appState.isLoading {
                        ProgressView().tint(GlassTheme.accent)
                    }
                }

                if let error = appState.errorMessage {
                    errorCard(error)
                }

                if isInitialLoad {
                    loadingSkeleton
                } else {

                GlassCard {
                    VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                        Text("Overview")
                            .font(.headline)
                            .foregroundStyle(GlassTheme.primary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: GlassTheme.Space.m)], spacing: GlassTheme.Space.m) {
                            metric("Cameras", value: "\(appState.stats?.cameras?.count ?? appState.cameras.count)")
                            metric("Detectors", value: "\(appState.stats?.detectors?.count ?? 0)")
                            metric("Events", value: "\(appState.events.count)")
                            // Realtime reflects the live WebSocket, not just the last REST call —
                            // so a `/ws` that's silently dropped by a reverse proxy reads
                            // "Reconnecting" here instead of a misleading "Healthy".
                            metric(
                                "Realtime",
                                value: appState.isLive ? "Live" : "Reconnecting",
                                state: appState.isLive ? .live : .recording
                            )
                            metric(
                                "Status",
                                value: appState.errorMessage == nil ? "Healthy" : "Needs attention",
                                state: appState.errorMessage == nil ? .live : .recording
                            )
                        }
                    }
                }

                if let detectors = appState.stats?.detectors, !detectors.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                            Text("Detectors")
                                .font(.headline)
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
                        VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                            Text("Camera Performance")
                                .font(.headline)
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

                if let storage = appState.stats?.service?.storage, !storage.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                            Text("Storage")
                                .font(.headline)
                                .foregroundStyle(GlassTheme.primary)
                            ForEach(storage.sorted(by: { $0.key < $1.key }), id: \.key) { mount, value in
                                storageRow(mount: mount, value: value)
                            }
                        }
                    }
                }

                if !appState.recentLogs.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                            Text("Recent Logs")
                                .font(.headline)
                                .foregroundStyle(GlassTheme.primary)

                            ForEach(appState.recentLogs.suffix(10), id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(GlassTheme.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(3)
                            }
                        }
                    }
                }

                } // end content (non-loading) branch
            }
            .padding(GlassTheme.Space.l)
            .animation(.easeInOut(duration: 0.25), value: isInitialLoad)
            }
        }
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        // Stats + logs are fetched here, on demand, instead of on every app refresh.
        .task { await appState.loadSystemHealth() }
        .refreshable { await appState.loadSystemHealth() }
    }

    // MARK: - Loading & Error states

    /// Skeleton that mirrors the overview metric grid + a detail card while the first
    /// stats fetch is running, so the screen shows its shape instead of empty zeros.
    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
            GlassCard {
                VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                    SkeletonBlock().frame(width: 110, height: 17)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: GlassTheme.Space.m)], spacing: GlassTheme.Space.m) {
                        ForEach(0..<4, id: \.self) { _ in
                            SkeletonBlock(cornerRadius: GlassTheme.Radius.tile).frame(height: 58)
                        }
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                    SkeletonBlock().frame(width: 130, height: 17)
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: GlassTheme.Space.m) {
                            SkeletonBlock(cornerRadius: 18).frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                                SkeletonBlock().frame(width: 120, height: 14)
                                SkeletonBlock().frame(width: 180, height: 12)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// A calm error banner with a one-tap retry, shown above the (possibly stale) cards
    /// so the user always knows when a fetch failed and can recover without leaving.
    private func errorCard(_ message: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                HStack(alignment: .top, spacing: GlassTheme.Space.m) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(GlassTheme.orange)
                        .frame(width: 38, height: 38)
                        .background(GlassTheme.orange.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                        Text("Couldn't reach Frigate")
                            .font(.headline)
                            .foregroundStyle(GlassTheme.primary)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(GlassTheme.secondary)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    Haptics.tap()
                    Task { await appState.refresh() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                .disabled(appState.isLoading)
            }
        }
    }

    private func metric(_ label: String, value: String, state: StatusDot.Mode? = nil) -> some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GlassTheme.secondary)
            HStack(spacing: GlassTheme.Space.s) {
                if let state {
                    StatusDot(state: state)
                }
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GlassTheme.Space.m)
        .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
        .cardStroke(GlassTheme.Radius.tile)
        // Combine label + status dot + value into one VoiceOver stop instead of 2-3 separate ones.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label). \(value)")
    }

    private func infoRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: GlassTheme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GlassTheme.accent)
                .frame(width: 36, height: 36)
                .background(GlassTheme.surfaceHigh, in: Circle())
                .overlay { Circle().strokeBorder(GlassTheme.separator, lineWidth: 1) }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.secondary)
            }
            Spacer()
        }
        .padding(.vertical, GlassTheme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private func format(_ value: Double?, suffix: String) -> String {
        guard let value else { return "n/a" }
        return "\(String(format: value >= 10 ? "%.0f" : "%.1f", value))\(suffix)"
    }

    // MARK: - Storage

    @ViewBuilder
    private func storageRow(mount: String, value: JSONValue) -> some View {
        let total = numberValue(value, key: "total")
        let used = numberValue(value, key: "used")
        let fraction = (total ?? 0) > 0 ? min(1, (used ?? 0) / (total ?? 1)) : 0

        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
            HStack(spacing: GlassTheme.Space.s) {
                Image(systemName: "internaldrive.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GlassTheme.secondary)
                Text(mountLabel(mount))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                    .lineLimit(1)
                Spacer()
                if let used, let total {
                    Text("\(gb(used)) / \(gb(total))")
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(GlassTheme.surfaceHigh)
                    Capsule()
                        .fill(storageColor(fraction))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, GlassTheme.Space.xs)
        // The used/total percentage is otherwise conveyed only by bar WIDTH — invisible to
        // VoiceOver without an explicit value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mountLabel(mount))
        .accessibilityValue(
            used != nil && total != nil
                ? "\(gb(used!)) of \(gb(total!)) used, \(Int(fraction * 100)) percent"
                : "Unknown"
        )
    }

    private func storageColor(_ fraction: Double) -> Color {
        if fraction > 0.9 { return GlassTheme.red }
        if fraction > 0.75 { return GlassTheme.orange }
        return GlassTheme.accent
    }

    private func numberValue(_ value: JSONValue, key: String) -> Double? {
        guard case let .object(obj) = value, case let .number(n) = obj[key] else { return nil }
        return n
    }

    private func gb(_ megabytes: Double) -> String {
        let value = megabytes / 1024
        return value >= 100 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }

    private func mountLabel(_ mount: String) -> String {
        (mount as NSString).lastPathComponent.isEmpty ? mount : (mount as NSString).lastPathComponent
    }
}
