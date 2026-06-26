import SwiftUI

struct PTZControlView: View {
    let cameraName: String
    let client: FrigateClient
    @State private var feedback: String?
    @State private var presets: [String] = []

    var body: some View {
        VStack(spacing: GlassTheme.Space.l) {
            HStack {
                Text("PTZ Controls")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.secondary)
                Spacer()
                if let msg = feedback {
                    Text(msg)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                        .transition(.opacity)
                }
            }

            HStack(spacing: GlassTheme.Space.xxl) {
                dpad
                zoomStack
            }

            if !presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: GlassTheme.Space.s) {
                        ForEach(presets, id: \.self) { preset in
                            Button {
                                // Haptic comes from the unified .sensoryFeedback below.
                                send(action: "preset", extra: ["preset": preset])
                            } label: {
                                Text(preset)
                            }
                            .buttonStyle(PillButtonStyle())
                            .accessibilityLabel("Go to preset \(preset)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(GlassTheme.Space.l)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
        .cardStroke(GlassTheme.Radius.card)
        // One light tick when a move command lands — not per repeat-tick, so a held
        // direction confirms once instead of rattling. An error buzzes distinctly.
        .sensoryFeedback(trigger: feedback) { _, new in
            switch new {
            case "Error": return .error
            case .some: return .impact(weight: .light)
            case nil: return nil
            }
        }
        .task { await loadPresets() }
    }

    private var dpad: some View {
        VStack(spacing: GlassTheme.Space.s) {
            ptzButton(icon: "chevron.up", action: "move_up", label: "Tilt up")
            HStack(spacing: GlassTheme.Space.s) {
                ptzButton(icon: "chevron.left", action: "move_left", label: "Pan left")
                stopButton
                ptzButton(icon: "chevron.right", action: "move_right", label: "Pan right")
            }
            ptzButton(icon: "chevron.down", action: "move_down", label: "Tilt down")
        }
    }

    private var zoomStack: some View {
        VStack(spacing: GlassTheme.Space.s) {
            ptzButton(icon: "plus.magnifyingglass", action: "zoom_in", label: "Zoom in")
            ptzButton(icon: "minus.magnifyingglass", action: "zoom_out", label: "Zoom out")
        }
    }

    private var stopButton: some View {
        Button {
            // Haptic confirmation comes from the unified .sensoryFeedback below (keyed to
            // the feedback label) so stop doesn't double-buzz.
            send(action: "stop")
        } label: {
            RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 48, height: 48)
                .overlay {
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                        .strokeBorder(GlassTheme.separator, lineWidth: 1)
                }
                .overlay(
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(GlassTheme.secondary)
                )
        }
        .accessibilityLabel("Stop movement")
    }

    private func ptzButton(icon: String, action: String, label: String) -> some View {
        Button {
            // No explicit per-tap haptic here: button-repeat fires this closure continuously
            // while held, so a per-tick buzz would feel like a rattle. The unified
            // .sensoryFeedback (keyed to the feedback label) gives one tick when the move
            // lands, and the on-screen label confirms it visually.
            send(action: action)
        } label: {
            RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 48, height: 48)
                .overlay {
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                        .strokeBorder(GlassTheme.separator, lineWidth: 1)
                }
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GlassTheme.accent)
                )
        }
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }

    private func send(action: String, extra: [String: String] = [:]) {
        Task {
            do {
                try await client.ptzMove(camera: cameraName, action: action, extra: extra)
                withAnimation { feedback = action.replacingOccurrences(of: "_", with: " ").capitalized }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation { feedback = nil }
            } catch {
                withAnimation { feedback = "Error" }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation { feedback = nil }
            }
        }
    }

    private func loadPresets() async {
        guard let info = try? await client.ptzInfo(camera: cameraName) else { return }
        if case .object(let dict) = info,
           case .array(let arr) = dict["presets"] {
            presets = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
    }
}
