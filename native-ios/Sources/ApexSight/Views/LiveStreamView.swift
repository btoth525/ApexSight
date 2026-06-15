import SwiftUI
import WebKit

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
        case live = "Live"          // go2rtc HLS (fMP4) via AVPlayer — native, auto-starts, PiP
        case hd = "WebRTC"          // go2rtc WebRTC in a web view — LAN ultra-low latency
        case lite = "MJPEG"         // MJPEG detect stream — last-resort fallback, always works
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
        case .hd:
            webrtcView
        case .lite:
            liteMJPEG
        case .snapshot:
            snapshotView
        }
    }

    private var liveHLS: some View {
        // AVPlayer HLS (go2rtc fMP4). Pinch/pan/double-tap zoom + reconnect are built in.
        HLSLivePlayerView(
            camera: camera,
            preferSub: false,
            showControls: true,
            onPlaying: { playing in withAnimation(.easeIn(duration: 0.2)) { isLive = playing } }
        )
        .id(reloadToken)
    }

    private var liteMJPEG: some View {
        ZoomableScrollView {
            ZStack {
                // Snapshot underneath for instant feedback while the stream connects.
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

    private var webrtcView: some View {
        Group {
            if let client = appState.client, let session = appState.session {
                WebRTCView(url: client.webRTCPlayerURL(camera: camera.name), session: session)
                    .id(reloadToken)
            } else {
                unavailable("HD stream not available")
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

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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
        case .hd: return .green
        case .live, .lite: return isLive ? .green : .yellow
        }
    }

    private var statusText: String {
        switch streamMode {
        case .snapshot: return "Snapshot"
        case .hd: return "HD Live"
        case .lite: return isLive ? "Lite" : "Connecting…"
        case .live: return isLive ? "Live" : "Connecting…"
        }
    }

    private func icon(for mode: StreamMode) -> String {
        switch mode {
        case .live: return "dot.radiowaves.up.forward"
        case .hd: return "tv.fill"
        case .lite: return "bolt.horizontal.fill"
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
                // Always available — every Frigate camera with recordings exposes a timeline.
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

// MARK: - WebRTC via go2rtc embedded player

struct WebRTCView: UIViewRepresentable {
    let url: URL
    let session: FrigateSession

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Auto-click go2rtc's play button as soon as the page is ready.
        // The WKWebView trust context counts as user interaction so autoplay is permitted.
        let autoplay = WKUserScript(
            source: """
            (function() {
                function tryPlay() {
                    var btn = document.querySelector('button');
                    if (btn) { btn.click(); return; }
                    setTimeout(tryPlay, 200);
                }
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', tryPlay);
                } else {
                    tryPlay();
                }
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(autoplay)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        injectCookie(into: webView)
        // Load once here; the parent uses .id(reloadToken) to force a fresh instance on refresh.
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

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
