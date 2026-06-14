import SwiftUI

enum GlassTheme {
    static let background = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let primary = Color(red: 0.95, green: 0.95, blue: 0.97)
    static let secondary = Color.white.opacity(0.64)
    static let tertiary = Color.white.opacity(0.38)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let cyan = Color(red: 0.39, green: 0.82, blue: 1.0)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
}

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
    }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color = GlassTheme.blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .800))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(tint, in: Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
