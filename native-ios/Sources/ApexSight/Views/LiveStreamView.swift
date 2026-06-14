import SwiftUI
import AVKit

struct LiveStreamView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var streamMode: StreamMode = .hls
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showPTZ = false
    @State private var capability: CameraCapability?

    enum StreamMode: String, CaseIterable {
        case hls = "HLS"
        case snapshot = "Snapshot"
    }

    private var hlsURL: URL? {
        appState.client?.liveHLSURL(camera: camera.name)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch streamMode {
            case .hls:
                hlsPlayerView
            case .snapshot:
                snapshotView
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .navigationBarHidden(true)
        .task {
            capability = appState.capabilities.first(where: { $0.camera == camera.name })
            startHLS()
        }
        .onDisappear { player?.pause() }
    }

    private var hlsPlayerView: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
    }

    private var snapshotView: some View {
        Group {
            if let client = appState.client {
                RemoteImage(url: client.latestFrameURL(camera: camera.name), contentMode: .fit)
                    .ignoresSafeArea()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .black))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.15), in: Circle())
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(titleize(camera.name))
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                Text("Live")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.green)
            }

            Spacer()

            Picker("Stream", selection: $streamMode) {
                ForEach(StreamMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            if capability?.hasPtz == true {
                Button {
                    showPTZ.toggle()
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .black))
                        .frame(width: 40, height: 40)
                        .background(showPTZ ? .cyan.opacity(0.4) : .white.opacity(0.15), in: Circle())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 56)
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            if showPTZ, let client = appState.client {
                PTZControlView(cameraName: camera.name, client: client)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 20) {
                actionButton(icon: "arrow.clockwise", label: "Refresh") {
                    if streamMode == .hls { startHLS() }
                }
                actionButton(icon: "photo", label: "Snapshot") {
                    streamMode = .snapshot
                }
                if capability?.hasRecordings == true {
                    NavigationLink {
                        RecordingBrowserView(camera: camera)
                    } label: {
                        actionButtonContent(icon: "clock.arrow.circlepath", label: "Recordings")
                    }
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

    private func startHLS() {
        player?.pause()
        player = nil
        isLoading = true
        errorMessage = nil

        guard let url = hlsURL, let client = appState.client else {
            errorMessage = "No Frigate connection."
            isLoading = false
            return
        }
        let item = client.playerItem(for: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        newPlayer.play()
        player = newPlayer
        isLoading = false
    }
}
