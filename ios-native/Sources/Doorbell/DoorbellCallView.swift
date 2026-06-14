import SwiftUI
import AVFoundation

struct DoorbellCallView: View {
    let cameraName: String
    let callUUID: UUID

    @EnvironmentObject var doorbellManager: DoorbellManager
    @State private var webView: WKWebView?
    @State private var isTalking = false

    // Pre-warm WS URL built once when view appears
    private var wsURL: URL? { FrigateAPI.shared.webRTCWebSocketURL(camera: cameraName) }
    private var baseURL: URL? { URL(string: FrigateAPI.shared.baseURL) }
    private var audioWsURL: URL? { FrigateAPI.shared.doorbellAudioWSURL() }

    @Environment(\.safeAreaInsets) private var safeArea

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // WebRTC video feed
            if let ws = wsURL, let base = baseURL {
                WebRTCCallView(wsURL: ws, baseURL: base, webView: $webView)
                    .ignoresSafeArea()
            }

            // Top pill — caller name + status
            VStack {
                CallerPill(label: cameraName, subtitle: isTalking ? "Speaking…" : "Live")
                    .padding(.top, safeArea.top + 12)
                Spacer()
            }

            // Bottom controls
            VStack {
                Spacer()
                HStack(spacing: 48) {
                    // Mic toggle
                    CallButton(
                        icon: isTalking ? "mic.fill" : "mic.slash.fill",
                        color: isTalking ? .green : Color.white.opacity(0.2),
                        size: 64
                    ) {
                        toggleMic()
                    }

                    // End call
                    CallButton(
                        icon: "phone.down.fill",
                        color: .red,
                        size: 72,
                        iconRotation: 0
                    ) {
                        endCall()
                    }
                }
                .padding(.bottom, safeArea.bottom + 44)
            }
        }
        .onAppear {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        .onDisappear {
            stopMic()
        }
    }

    // MARK: - Actions

    private func toggleMic() {
        if isTalking {
            stopMic()
        } else {
            startMic()
        }
    }

    private func startMic() {
        guard let url = audioWsURL else { return }
        isTalking = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        webView?.evaluateJavaScript("window._startTalkback(\(jsonString(url.absoluteString))); true;")
    }

    private func stopMic() {
        guard isTalking else { return }
        isTalking = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        webView?.evaluateJavaScript("window._stopTalkback(); true;")
    }

    private func endCall() {
        stopMic()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        doorbellManager.endCall(uuid: callUUID)
    }

    private func jsonString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

// MARK: - Sub-views

private struct CallerPill: View {
    let label: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct CallButton: View {
    let icon: String
    let color: Color
    let size: CGFloat
    var iconRotation: Double = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .shadow(color: color.opacity(0.5), radius: 12, y: 4)

                Image(systemName: icon)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(iconRotation))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Safe area helper

private struct SafeAreaInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    var safeAreaInsets: EdgeInsets {
        get { self[SafeAreaInsetsKey.self] }
        set { self[SafeAreaInsetsKey.self] = newValue }
    }
}
