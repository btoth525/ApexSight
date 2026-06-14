import SwiftUI
import AVKit
import AVFoundation

struct LiveStreamView: View {
    let cameraName: String

    @StateObject private var playerVM: PlayerViewModel
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @Environment(\.dismiss) private var dismiss

    init(cameraName: String) {
        self.cameraName = cameraName
        _playerVM = StateObject(wrappedValue: PlayerViewModel(cameraName: cameraName))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayerView(player: playerVM.player)
                .ignoresSafeArea()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastScale
                            lastScale = value
                            scale = min(max(scale * delta, 1.0), 4.0)
                        }
                        .onEnded { _ in lastScale = 1.0 }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) { scale = 1.0 }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

            // PiP button
            VStack {
                HStack {
                    Spacer()
                    if playerVM.pipController?.isPictureInPicturePossible == true {
                        Button {
                            if playerVM.pipController?.isPictureInPictureActive == true {
                                playerVM.pipController?.stopPictureInPicture()
                            } else {
                                playerVM.pipController?.startPictureInPicture()
                            }
                        } label: {
                            Image(systemName: "pip.enter")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding()
                    }
                }
                Spacer()
            }
        }
        .navigationTitle(cameraName.replacingOccurrences(of: "_", with: " ").capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onDisappear { playerVM.stop() }
    }
}

// MARK: - Player ViewModel

@MainActor
final class PlayerViewModel: ObservableObject {
    let player: AVPlayer
    var pipController: AVPictureInPictureController?
    private var playerLayer: AVPlayerLayer?

    init(cameraName: String) {
        guard let url = FrigateAPI.shared.hlsURL(for: cameraName) else {
            player = AVPlayer()
            return
        }
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.play()
    }

    func attachPiP(to layer: AVPlayerLayer) {
        playerLayer = layer
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: layer)
        }
    }

    func stop() {
        player.pause()
        pipController?.stopPictureInPicture()
    }
}

// MARK: - UIViewRepresentable wrapper

private struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspectFill
        }
    }
}
