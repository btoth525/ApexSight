import SwiftUI

/// Full-screen privacy cover shown while the app is locked. Hides all camera content
/// (including in the app switcher) until the user passes Face ID / Touch ID / passcode.
struct LockOverlayView: View {
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            // Opaque so nothing behind it leaks into the app-switcher snapshot.
            Color.black.ignoresSafeArea()
            LinearGradient(
                colors: [Color.cyan.opacity(0.18), .clear],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 54, weight: .black))
                    .foregroundStyle(.cyan)
                Text("ApexSight Locked")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(.white)
                Text("Your cameras are private. Unlock to continue.")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)

                Button(action: onUnlock) {
                    Label("Unlock with \(BiometricLock.label)", systemImage: BiometricLock.symbolName)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(.cyan, in: Capsule())
                }
                .padding(.top, 4)
            }
            .padding(32)
        }
    }
}
