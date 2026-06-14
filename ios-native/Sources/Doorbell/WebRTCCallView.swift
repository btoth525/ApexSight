import SwiftUI
import WebKit

// WKWebView container that runs the injected go2rtc WebRTC HTML.
// Exposes injectJS(_:) so DoorbellCallView can trigger talkback from Swift.

struct WebRTCCallView: UIViewRepresentable {
    let wsURL: URL
    let baseURL: URL

    @Binding var webView: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.backgroundColor = .black
        wv.isOpaque = true
        wv.scrollView.isScrollEnabled = false

        let html = DoorbellStream.webRTCHtml(wsURL: wsURL)
        wv.loadHTMLString(html, baseURL: baseURL)

        DispatchQueue.main.async { self.webView = wv }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
