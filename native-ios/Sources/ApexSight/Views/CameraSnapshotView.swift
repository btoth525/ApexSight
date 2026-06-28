import SwiftUI

/// A calm "warming up" indicator shown over a camera's cached snapshot until its live stream
/// produces a first frame, so a tile never reads as frozen or dead-black while connecting.
/// (Used by CameraCard and the multi-camera wall.)
struct ConnectingHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        // Fill and self-center so the dot always sits mid-tile regardless of the parent
        // ZStack's alignment (cards align .bottom, wall cells align .bottomLeading).
        Circle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 10, height: 10)
            .scaleEffect(reduceMotion ? 1 : (breathe ? 1.0 : 0.6))
            .opacity(reduceMotion ? 0.7 : (breathe ? 0.85 : 0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
            .accessibilityHidden(true)
    }
}
