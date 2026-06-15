import SwiftUI
import UIKit

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @EnvironmentObject private var appState: AppState
    @State private var image: Image?
    @State private var isFailed = false

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isFailed {
                placeholder
            } else {
                placeholder
                    .overlay { ProgressView().tint(GlassTheme.cyan) }
            }
        }
        .task(id: url) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: "photo")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    private func load() async {
        guard let url else {
            isFailed = true
            return
        }
        // Show the cached image instantly — no black flash when a cell reappears.
        if let cached = ImageCache.shared.image(for: url) {
            image = Image(uiImage: cached)
            isFailed = false
            return
        }
        image = nil
        isFailed = false

        // A few quick retries smooth over transient network blips and the brief
        // window while an expired token is being refreshed, so a thumbnail recovers
        // on its own instead of leaving a permanent blank tile. The client is
        // re-read each pass so a freshly re-authenticated session is picked up.
        for attempt in 0..<3 {
            guard let client = appState.client else { break }
            do {
                let data = try await client.imageData(from: url)
                if let uiImage = UIImage(data: data) {
                    ImageCache.shared.insert(uiImage, for: url)
                    image = Image(uiImage: uiImage)
                    isFailed = false
                    return
                }
            } catch {
                if error.isCancellation { return }
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        isFailed = true
    }
}
