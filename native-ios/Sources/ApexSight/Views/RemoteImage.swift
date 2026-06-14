import SwiftUI

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
                placeholder(systemName: "photo")
            } else {
                placeholder(systemName: "photo")
                    .overlay {
                        ProgressView()
                            .tint(GlassTheme.cyan)
                    }
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url, let client = appState.client else {
            isFailed = true
            return
        }

        do {
            let data = try await client.imageData(from: url)
            #if os(iOS)
            if let uiImage = UIImage(data: data) {
                image = Image(uiImage: uiImage)
                isFailed = false
                return
            }
            #endif
            isFailed = true
        } catch {
            isFailed = true
        }
    }

    private func placeholder(systemName: String) -> some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(GlassTheme.secondary)
        }
    }
}
