import SwiftUI
import AVKit
import CoreMedia
import WebKit

struct LiveStreamView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var streamMode: StreamMode = .webrtc
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showPTZ = false
    @State private var capability: CameraCapability?
    @State private var stallObserver: NSKeyValueObservation?
    @State private var statusObserver: NSKeyValueObservation?

    enum StreamMode: String, CaseIterable {
        case webrtc = "WebRTC"
        case hls = "HLS"
        case snapshot = "Snapshot"
    }

    private var hlsURL: URL? {
        appState.client?.liveHLSURL(camera: camera.name)
    }

    private var webrtcURL: URL? {
        guard let base = appState.session?.baseURL else { return nil }
        return base.appending(path: "/live/webrtc").appending(queryItems: [URLQueryItem(name: "src", value: camera.name)])
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch streamMode {
            case .webrtc:
                webrtcView
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
            // Default to HLS — more reliable. WebRTC only if user explicitly selects it.
            streamMode = .hls
            startHLS()
        }
        .onChange(of: streamMode) { _, mode in
            statusObserver = nil
            if mode == .hls {
                startHLS()
            } else {
                stallObserver = nil
                player?.pause()
                player = nil
                isLoading = false
            }
        }
        .onDisappear {
            player?.pause()
            stallObserver = nil
            statusObserver = nil
        }
    }

    private var webrtcView: some View {
        Group {
            if let url = webrtcURL, let session = appState.session {
                WebRTCView(url: url, session: session)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("WebRTC not available")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }

    private var hlsPlayerView: some View {
        Group {
            if let player {
                PiPPlayerView(player: player, showsControls: false)
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
                        .fill(streamMode == .snapshot ? .orange : .green)
                        .frame(width: 6, height: 6)
                    Text(streamMode == .snapshot ? "Snapshot" : "Live")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(streamMode == .snapshot ? .orange : .green)
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

    private func icon(for mode: StreamMode) -> String {
        switch mode {
        case .webrtc: return "dot.radiowaves.up.forward"
        case .hls: return "play.tv.fill"
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
        stallObserver = nil
        statusObserver = nil
        player = nil
        isLoading = true
        errorMessage = nil

        guard let url = hlsURL, let client = appState.client else {
            errorMessage = "No Frigate connection."
            isLoading = false
            return
        }

        let item = client.playerItem(for: url)
        item.preferredForwardBufferDuration = 4
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.play()
        player = newPlayer

        // Show video once ready, error if failed.
        // Note: LiveStreamView is a struct, so self cannot be captured weakly.
        // @State storage is reference-backed, so direct mutation from this escaping closure is valid.
        statusObserver = item.observe(\.status, options: [.new]) { playerItem, _ in
            DispatchQueue.main.async {
                switch playerItem.status {
                case .readyToPlay:
                    isLoading = false
                    errorMessage = nil
                    // Seek to live edge
                    if let range = playerItem.seekableTimeRanges.last?.timeRangeValue {
                        newPlayer.seek(to: CMTimeRangeGetEnd(range))
                    }
                case .failed:
                    isLoading = false
                    errorMessage = playerItem.error?.localizedDescription ?? "Stream failed to load."
                    player = nil
                default:
                    break
                }
            }
        }

        // Stall recovery
        stallObserver = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak newPlayer] p, _ in
            guard p.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            if let range = p.currentItem?.seekableTimeRanges.last?.timeRangeValue {
                p.seek(to: CMTimeRangeGetEnd(range), toleranceBefore: .zero, toleranceAfter: .zero) { _ in p.play() }
            }
        }
    }
}

// MARK: - WebRTC via go2rtc embedded player

struct WebRTCView: UIViewRepresentable {
    let url: URL
    let session: FrigateSession

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.isOpaque = false
        injectCookie(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        webView.load(request)
    }

    private func injectCookie(into webView: WKWebView) {
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: "frigate_token",
            .value: session.token,
            .domain: session.baseURL.host() ?? "",
            .path: "/",
            .secure: session.baseURL.scheme == "https"
        ]
        if let cookie = HTTPCookie(properties: props) {
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
    }
}
