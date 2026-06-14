import SwiftUI

struct CameraCard: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = appState.client?.latestFrameURL(camera: camera.name) {
                RemoteImage(url: url)
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(titleize(camera.name))
                        .font(.system(size: 16, weight: .900))
                        .foregroundStyle(GlassTheme.primary)
                    Text("Latest Frigate frame")
                        .font(.system(size: 12, weight: .700))
                        .foregroundStyle(GlassTheme.secondary)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .900))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(GlassTheme.blue, in: Circle())
            }
            .padding(.top, 12)
        }
        .padding(10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }
}
