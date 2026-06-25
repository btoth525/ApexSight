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
                                send(action: "preset", extra: ["preset": preset])
                            } label: {
                                Text(preset)
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                    }
                }
            }
        }
        .padding(GlassTheme.Space.l)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
        .cardStroke(GlassTheme.Radius.card)
        .task { await loadPresets() }
    }

    private var dpad: some View {
        VStack(spacing: GlassTheme.Space.s) {
            ptzButton(icon: "chevron.up", action: "move_up")
            HStack(spacing: GlassTheme.Space.s) {
                ptzButton(icon: "chevron.left", action: "move_left")
                stopButton
                ptzButton(icon: "chevron.right", action: "move_right")
            }
            ptzButton(icon: "chevron.down", action: "move_down")
        }
    }

    private var zoomStack: some View {
        VStack(spacing: GlassTheme.Space.s) {
            ptzButton(icon: "plus.magnifyingglass", action: "zoom_in")
            ptzButton(icon: "minus.magnifyingglass", action: "zoom_out")
        }
    }

    private var stopButton: some View {
        Button {
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
    }

    private func ptzButton(icon: String, action: String) -> some View {
        Button {
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
