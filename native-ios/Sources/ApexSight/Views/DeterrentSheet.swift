import SwiftUI

/// Front Driveway deterrents — cop lights, siren, voice warning, and combos. Each taps the relay
/// (`/v1/deterrent`), which fires the matching Home Assistant webhook locally: WLED wig-wag lights,
/// the Reolink Duo 3V siren, and/or a spoken warning pushed into the camera speaker. Gated to the
/// driveway (the only camera with the speaker + lights); push-to-talk lives on the live view itself.
struct DeterrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var clip = "warning_medium_christopher.mp3"
    @State private var seconds = 5
    @State private var busy: DeterrentAction?
    @State private var justFired: DeterrentAction?
    @State private var errorText: String?
    @State private var clearFiredTask: Task<Void, Never>?

    private let clips: [(label: String, file: String)] = [
        ("Short (5s)", "warning_short_christopher.mp3"),
        ("Medium (8s)", "warning_medium_christopher.mp3"),
        ("Long (12s)", "warning_christopher.mp3"),
        ("Alt voice", "warning_guy.mp3"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                        settings
                        VStack(spacing: GlassTheme.Space.s) {
                            ForEach(DeterrentAction.allCases) { actionRow($0) }
                        }
                        if let errorText {
                            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(GlassTheme.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Fires instantly at the driveway. A repeat while one is running is ignored.")
                            .font(.caption).foregroundStyle(GlassTheme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(GlassTheme.Space.l)
                }
            }
            .navigationTitle("Driveway Deterrent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private var settings: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                HStack {
                    Label("Voice clip", systemImage: "waveform").font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    Menu {
                        ForEach(clips, id: \.file) { c in
                            Button { clip = c.file } label: {
                                if clip == c.file { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(clips.first { $0.file == clip }?.label ?? "Medium")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(GlassTheme.accent)
                    }
                }
                Divider().overlay(GlassTheme.separator)
                Stepper(value: $seconds, in: 3...20) {
                    HStack {
                        Label("Lights / siren", systemImage: "clock").font(.subheadline.weight(.semibold))
                            .foregroundStyle(GlassTheme.primary)
                        Spacer()
                        Text("\(seconds)s").font(.subheadline.weight(.bold)).monospacedDigit()
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
            }
        }
    }

    private func actionRow(_ action: DeterrentAction) -> some View {
        Button { fire(action) } label: {
            HStack(spacing: GlassTheme.Space.m) {
                ZStack {
                    Circle().fill(action.tint.opacity(0.18)).frame(width: 42, height: 42)
                    Image(systemName: action.icon).font(.system(size: 18, weight: .bold))
                        .foregroundStyle(action.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.headline).foregroundStyle(GlassTheme.primary)
                    Text(action.subtitle).font(.caption).foregroundStyle(GlassTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if busy == action {
                    ProgressView().tint(action.tint)
                } else if justFired == action {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(GlassTheme.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(GlassTheme.Space.m)
            .frame(maxWidth: .infinity)
            .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous)
                .stroke(GlassTheme.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .accessibilityLabel("\(action.title). \(action.subtitle)")
    }

    private func fire(_ action: DeterrentAction) {
        Haptics.press()
        let relay = DeviceTokenStore.relayURL
        guard !relay.isEmpty else {
            errorText = "The relay isn't set up yet (Settings ▸ Notifications)."
            Haptics.error(); return
        }
        errorText = nil
        busy = action
        Task {
            do {
                try await RelayClient.deterrent(
                    relayURL: relay,
                    pairingCode: DeviceTokenStore.ensurePairingCode(),
                    action: action.rawValue,
                    seconds: action.usesSeconds ? seconds : nil,
                    file: action.usesFile ? clip : nil)
                await MainActor.run {
                    busy = nil
                    Haptics.success()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) { justFired = action }
                    clearFiredTask?.cancel()
                    clearFiredTask = Task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        await MainActor.run { withAnimation { if justFired == action { justFired = nil } } }
                    }
                }
            } catch {
                await MainActor.run {
                    busy = nil
                    Haptics.error()
                    errorText = "Couldn't reach the relay. \(error.localizedDescription)"
                }
            }
        }
    }
}

/// The five driveway deterrent actions (mirrors the relay's `/v1/deterrent` action map).
enum DeterrentAction: String, CaseIterable, Identifiable {
    case copLights = "cop_lights"
    case voice
    case siren
    case lightsSiren = "lights_siren"
    case deterrent

    var id: String { rawValue }
    var usesSeconds: Bool { self != .voice }
    var usesFile: Bool { self == .voice || self == .deterrent }

    var title: String {
        switch self {
        case .copLights:   return "Cop Lights"
        case .voice:       return "Voice Warning"
        case .siren:       return "Siren"
        case .lightsSiren: return "Lights + Siren"
        case .deterrent:   return "Full Deterrent"
        }
    }
    var subtitle: String {
        switch self {
        case .copLights:   return "Red/blue wig-wag on the garage strips"
        case .voice:       return "Speak the warning at the camera"
        case .siren:       return "Reolink siren at full volume"
        case .lightsSiren: return "Lights and siren together"
        case .deterrent:   return "Lights + spoken warning"
        }
    }
    var icon: String {
        switch self {
        case .copLights:   return "light.beacon.max.fill"
        case .voice:       return "megaphone.fill"
        case .siren:       return "bell.and.waves.left.and.right.fill"
        case .lightsSiren: return "exclamationmark.triangle.fill"
        case .deterrent:   return "exclamationmark.shield.fill"
        }
    }
    var tint: Color {
        switch self {
        case .copLights:   return GlassTheme.accent
        case .voice:       return GlassTheme.teal
        case .siren:       return GlassTheme.red
        case .lightsSiren: return GlassTheme.orange
        case .deterrent:   return GlassTheme.red
        }
    }
}
