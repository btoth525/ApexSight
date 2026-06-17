import SwiftUI

struct LiveStreamView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var streamMode: StreamMode = .live
    @State private var isLive = false
    @State private var showPTZ = false
    @State private var capability: CameraCapability?
    @State private var reloadToken = UUID()

    enum StreamMode: String, CaseIterable {
        case live = "Live"
        case mjpeg = "MJPEG"
        case snapshot = "Snapshot"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .navigationBarHidden(true)
        .task {
            capability = appState.capabilities.first(where: { $0.camera == camera.name })
        }
        .onChange(of: streamMode) { _, _ in
            isLive = false
            reloadToken = UUID()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch streamMode {
        case .live:
            liveHLS
        case .mjpeg:
            liveMJPEG
        case .snapshot:
            snapshotView
        }
    }

    private var liveHLS: some View {
        // Frigate-style: SD shows instantly, then upgrades to HD and stays there.
        HLSLivePlayerView(
            camera: camera,
            showControls: true,
            preferSubStream: true,
            autoUpgradeToHD: true,
            onPlaying: { playing in withAnimation(.easeIn(duration: 0.2)) { isLive = playing } }
        )
        .id(reloadToken)
    }

    private var liveMJPEG: some View {
        ZoomableScrollView {
            ZStack {
                if let client = appState.client {
                    RemoteImage(url: client.latestFrameURL(camera: camera.name), contentMode: .fit)
                        .opacity(isLive ? 0 : 1)
                    MJPEGStreamView(
                        url: client.mjpegURL(camera: camera.name),
                        client: client,
                        contentMode: .scaleAspectFit,
                        onFirstFrame: { withAnimation(.easeIn(duration: 0.25)) { isLive = true } }
                    )
                    .id(reloadToken)
                    .opacity(isLive ? 1 : 0)
                }
                if !isLive {
                    ProgressView().tint(.white).scaleEffect(1.4)
                }
            }
        }
    }

    private var snapshotView: some View {
        ZoomableScrollView {
            if let client = appState.client {
                RemoteImage(url: client.latestFrameURL(camera: camera.name), contentMode: .fit)
                    .id(reloadToken)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .black))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(titleize(camera.name))
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(statusColor)
                }
            }

            Spacer(minLength: 6)

            Menu {
                Picker("Stream", selection: $streamMode) {
                    ForEach(StreamMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: icon(for: mode)).tag(mode)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: icon(for: streamMode))
                        .font(.system(size: 12, weight: .black))
                    Text(streamMode.rawValue)
                        .font(.system(size: 12, weight: .heavy))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .black))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
            }

            if capability?.hasPtz == true {
                Button {
                    showPTZ.toggle()
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .black))
                        .frame(width: 38, height: 38)
                        .background(showPTZ ? AnyShapeStyle(GlassTheme.cyan.opacity(0.4)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 54)
    }

    private var statusColor: Color {
        switch streamMode {
        case .snapshot: return .orange
        case .live, .mjpeg: return isLive ? .green : .yellow
        }
    }

    private var statusText: String {
        switch streamMode {
        case .snapshot: return "Snapshot"
        case .mjpeg: return isLive ? "MJPEG" : "Connecting…"
        case .live: return isLive ? "Live" : "Connecting…"
        }
    }

    private func icon(for mode: StreamMode) -> String {
        switch mode {
        case .live: return "dot.radiowaves.up.forward"
        case .mjpeg: return "bolt.horizontal.fill"
        case .snapshot: return "photo.fill"
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            if showPTZ, let client = appState.client {
                PTZControlView(cameraName: camera.name, client: client)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 20) {
                actionButton(icon: "arrow.clockwise", label: "Refresh") {
                    isLive = false
                    reloadToken = UUID()
                }
                actionButton(icon: "photo", label: "Snapshot") {
                    streamMode = .snapshot
                }
                NavigationLink {
                    RecordingBrowserView(camera: camera)
                } label: {
                    actionButtonContent(icon: "clock.arrow.circlepath", label: "Timeline")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionButtonContent(icon: icon, label: label)
        }
    }

    private func actionButtonContent(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.15), in: Circle())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
