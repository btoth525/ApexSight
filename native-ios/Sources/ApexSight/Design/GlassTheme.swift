import SwiftUI

enum GlassTheme {
    // MARK: - Backgrounds
    static let background = Color(red: 0.02, green: 0.02, blue: 0.04)
    static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.04, green: 0.04, blue: 0.12),
            Color(red: 0.01, green: 0.01, blue: 0.04)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Text
    static let primary   = Color(red: 0.96, green: 0.96, blue: 0.98)
    static let secondary = Color.white.opacity(0.60)
    static let tertiary  = Color.white.opacity(0.36)

    // MARK: - Accent palette
    static let blue   = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let cyan   = Color(red: 0.39, green: 0.82, blue: 1.00)
    static let green  = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let red    = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let purple = Color(red: 0.68, green: 0.42, blue: 1.00)
    static let teal   = Color(red: 0.22, green: 0.80, blue: 0.72)
    static let yellow = Color(red: 1.00, green: 0.84, blue: 0.20)
}

// MARK: - GlassCard

struct GlassCard<Content: View>: View {
    var material: Material = .regularMaterial
    let content: Content

    init(material: Material = .regularMaterial, @ViewBuilder content: () -> Content) {
        self.material = material
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(material, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 6)
    }
}

// MARK: - GlassBackground

struct GlassBackground: View {
    var body: some View {
        ZStack {
            GlassTheme.background.ignoresSafeArea()
            RadialGradient(
                colors: [GlassTheme.blue.opacity(0.12), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 460
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [GlassTheme.cyan.opacity(0.07), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [GlassTheme.purple.opacity(0.06), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 300
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - PillButtonStyle

struct PillButtonStyle: ButtonStyle {
    var tint: Color = GlassTheme.blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(tint, in: Capsule())
            .opacity(configuration.isPressed ? 0.70 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - GlassButtonStyle

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - View Helpers

extension View {
    func glassBackground() -> some View {
        self.background(GlassBackground())
    }

    /// Apple-style frosted navigation bar: always-visible ultra-thin material with
    /// a dark scheme so titles and buttons stay legible over the dark glass UI.
    func glassNavBar() -> some View {
        self
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
