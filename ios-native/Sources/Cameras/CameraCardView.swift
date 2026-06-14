import SwiftUI

struct CameraCardView: View {
    let cameraName: String
    let lastRefresh: Date

    @State private var image: UIImage?
    @State private var loadError = false
    @State private var lastUpdated: Date?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Snapshot image
            Group {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else if loadError {
                    Rectangle()
                        .fill(Color.red.opacity(0.15))
                        .overlay(
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.red.opacity(0.8))
                        )
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView())
                }
            }
            .frame(height: 120)
            .clipped()
            .cornerRadius(12)

            // Camera info overlay
            VStack(alignment: .leading, spacing: 2) {
                Text(cameraName.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption.bold())
                    .foregroundColor(.white)

                if let updated = lastUpdated {
                    Text(updated, style: .time)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .cornerRadius(12)
            )

            // Live dot
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(height: 120)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
        .task(id: lastRefresh) {
            await fetchSnapshot()
        }
    }

    private func fetchSnapshot() async {
        guard let url = FrigateAPI.shared.snapshotURL(for: cameraName) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                loadError = true
                return
            }
            if let img = UIImage(data: data) {
                image = img
                lastUpdated = Date()
                loadError = false
            }
        } catch {
            // Network errors on individual cards are silently retried on the next tick
            if image == nil { loadError = true }
        }
    }
}

#Preview {
    CameraCardView(cameraName: "front_door", lastRefresh: Date())
        .frame(width: 180)
        .preferredColorScheme(.dark)
}
