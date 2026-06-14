import SwiftUI

struct PTZControlView: View {
    let cameraName: String
    let client: FrigateClient
    @State private var feedback: String?
    @State private var presets: [String] = []

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("PTZ Controls")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if let msg = feedback {
                    Text(msg)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.cyan)
                        .transition(.opacity)
                }
            }

            HStack(spacing: 24) {
                dpad
                zoomStack
            }

            if !presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { preset in
                            Button {
                                send(action: "preset", extra: ["preset": preset])
                            } label: {
                                Text(preset)
                                    .font(.system(size: 12, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.cyan, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task { await loadPresets() }
    }

    private var dpad: some View {
        VStack(spacing: 4) {
            ptzButton(icon: "chevron.up", action: "move_up")
            HStack(spacing: 4) {
                ptzButton(icon: "chevron.left", action: "move_left")
                stopButton
                ptzButton(icon: "chevron.right", action: "move_right")
            }
            ptzButton(icon: "chevron.down", action: "move_down")
        }
    }

    private var zoomStack: some View {
        VStack(spacing: 4) {
            ptzButton(icon: "plus.magnifyingglass", action: "zoom_in")
            ptzButton(icon: "minus.magnifyingglass", action: "zoom_out")
        }
    }

    private var stopButton: some View {
        Button {
            send(action: "stop")
        } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.1))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                )
        }
    }

    private func ptzButton(icon: String, action: String) -> some View {
        Button {
            send(action: action)
        } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
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
