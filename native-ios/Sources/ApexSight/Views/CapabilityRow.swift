import SwiftUI

struct CapabilityRow: View {
    let capability: CameraCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(titleize(capability.camera))
                    .font(.system(size: 15, weight: .900))
                    .foregroundStyle(GlassTheme.primary)
                Spacer()
                if capability.hasLatestFrame {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(GlassTheme.green)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    chip("Snapshot", active: capability.hasLatestFrame)
                    chip("Recordings", active: capability.hasRecordings)
                    chip("WebRTC", active: capability.hasGo2RtcStream)
                    chip("PTZ", active: capability.hasPtz)
                    if !capability.zones.isEmpty {
                        chip("\(capability.zones.count) Zones", active: true)
                    }
                    if !capability.objects.isEmpty {
                        chip("\(capability.objects.count) Objects", active: true)
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func chip(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .900))
            .foregroundStyle(active ? GlassTheme.green : GlassTheme.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background((active ? GlassTheme.green : Color.white).opacity(active ? 0.14 : 0.08), in: Capsule())
    }
}
