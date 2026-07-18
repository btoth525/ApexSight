import SwiftUI

/// Full-screen privacy cover shown while the app is locked. Hides all camera content
/// (including in the app switcher) until the user passes Face ID / Touch ID / passcode.
struct LockOverlayView: View {
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            // Opaque so nothing behind it leaks into the app-switcher snapshot.
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [GlassTheme.accent.opacity(0.14), .clear],
                center: .top, startRadius: 0, endRadius: 420
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 54, weight: .black))
                    .foregroundStyle(GlassTheme.accent)
                // Scalable semantic styles (not fixed-pixel sizes) so this screen — the one
                // every user must pass to reach the app — actually grows with Dynamic Type.
                Text("ApexSight Locked")
                    .font(.system(.title2, design: .default).weight(.black))
                    .foregroundStyle(.white)
                Text("Your cameras are private. Unlock to continue.")
                    .font(.system(.subheadline, design: .default).weight(.heavy))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)

                Button(action: onUnlock) {
                    Label("Unlock with \(BiometricLock.label)", systemImage: BiometricLock.symbolName)
                        .font(.system(.headline, design: .default).weight(.black))
                }
                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                .padding(.top, 4)
            }
            .padding(32)
        }
    }
}

/// Opaque privacy cover shown whenever the app is not active (app switcher, Control Center
/// pull, incoming call) — independent of the optional Face ID lock. Without this, the default
/// user (who never turns on the biometric lock) has their live camera frames captured into the
/// multitasking snapshot. No unlock affordance: it clears itself the moment the app is active.
struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [GlassTheme.accent.opacity(0.14), .clear],
                center: .top, startRadius: 0, endRadius: 420
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 48, weight: .black))
                    .foregroundStyle(GlassTheme.accent)
                Text("ApexSight")
                    .font(.system(.title3, design: .default).weight(.black))
                    .foregroundStyle(.white)
            }
        }
    }
}
