import SwiftUI

/// A full-screen "someone's at the door" call, styled like FaceTime but showing the real feed.
/// Answering (native CallKit or the in-app ring) drops you straight into the **live** doorbell
/// video, unmuted so you hear the visitor — and a soundboard strip lets you speak back: quick
/// replies, typed text in an on-device voice, or hold-to-talk. Talkback runs through the relay to
/// the doorbell speaker. Presented from the `apex://doorbell` deep link / VoIP call.
struct DoorbellCallView: View {
    /// When presented from the native CallKit answer, connect immediately (skip the in-app ring).
    var autoAnswer: Bool = false

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var soundboard = DoorbellSoundboard()

    @State private var answered = false
    @State private var pulse = false
    @State private var ringTask: Task<Void, Never>?

    private var camera: FrigateCamera? { appState.cameras.first { $0.name == "doorbell" } }

    private var statusText: String {
        answered ? "Live" : "Ringing…"   // answered: you see + hear the visitor
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Live doorbell feed — muted until answered (Answer opens the two-way audio path).
            if let camera {
                HLSLivePlayerView(
                    camera: camera,
                    showControls: false,
                    overlayControlsVisible: false,
                    pipController: nil,
                    onSingleTap: {},
                    onPlaying: { _ in },
                    onRealtimeChange: { _ in },
                    externalControls: true,
                    muted: !answered,
                    allowMJPEGFallback: false   // stay on full-res HLS; never flash low-res mid-call
                )
                .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }

            // Legibility scrims top + bottom.
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Spacer()
                controls
            }
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.top, GlassTheme.Space.l)
            .padding(.bottom, GlassTheme.Space.xl)
        }
        .preferredColorScheme(.dark)
        .task { if autoAnswer { beginListening() } else { startRinging() } }
        .onDisappear { ringTask?.cancel() }
    }

    private var header: some View {
        VStack(spacing: GlassTheme.Space.s) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 74, height: 74)
                    .scaleEffect(pulse ? 1.18 : 1)
                    .opacity(pulse ? 0 : 0.9)
                Circle().fill(.white.opacity(0.16)).frame(width: 66, height: 66)
                Image(systemName: "bell.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(pulse && !answered ? 8 : -8))
                    .animation(reduceMotion || answered ? nil : .easeInOut(duration: 0.35).repeatForever(autoreverses: true), value: pulse)
            }
            Text("Front Doorbell")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text(statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                .contentTransition(.opacity)
        }
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
    }

    private var controls: some View {
        Group {
            if answered {
                // Stage 2: watching live + hearing the visitor. The soundboard lets you speak back
                // (quick replies / typed text / hold-to-talk) through the door; End hangs up.
                VStack(spacing: GlassTheme.Space.m) {
                    if soundboard.available {
                        DoorbellSoundboardStrip(soundboard: soundboard)
                    }
                    callButton(system: "phone.down.fill", tint: .red, label: "End") { end() }
                }
            } else {
                // Stage 1: ringing. Answer drops into the live view (stage 2).
                HStack(alignment: .top, spacing: 0) {
                    callButton(system: "xmark", tint: .red, label: "Decline") { end() }
                    Spacer()
                    callButton(system: "phone.fill", tint: .green, label: "Answer") { beginListening() }
                }
                .padding(.horizontal, GlassTheme.Space.xl)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: answered)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: soundboard.available)
    }

    private func callButton(system: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: GlassTheme.Space.s) {
            Button(action: { Haptics.tap(); action() }) {
                Image(systemName: system)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(tint, in: Circle())
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 92)
    }

    // MARK: - Actions

    private func startRinging() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
            pulse = true
        }
        // A gentle repeating ring haptic until answered/declined.
        ringTask = Task { @MainActor in
            while !Task.isCancelled && !answered {
                Haptics.tap()
                try? await Task.sleep(nanoseconds: 1_800_000_000)
            }
        }
    }

    /// Stage 1 → 2: answering the ring drops you into the live view, unmuted so you hear the
    /// visitor. You're watching + listening; the soundboard lets you speak back. Probe talkback
    /// availability once here (never during playback).
    private func beginListening() {
        ringTask?.cancel()
        answered = true
        Haptics.success()
        Task { await soundboard.refresh() }
    }

    private func end() {
        ringTask?.cancel()
        // Clear the CallKit call too (if this ring came in as a VoIP call).
        DoorbellCallManager.shared.endCurrentCall()
        dismiss()
    }
}
