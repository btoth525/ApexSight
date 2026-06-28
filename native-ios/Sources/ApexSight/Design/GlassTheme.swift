import SwiftUI

/// Central design system. Dark-first, content-forward (camera imagery is the hero),
/// translucent material only on chrome, one accent, semantic status colors, hairline
/// separators instead of heavy shadows. Existing names are preserved so every screen keeps
/// compiling; new semantic tokens are added on top.
enum GlassTheme {
    // MARK: - Layered backgrounds (depth via solid layers, not blur-on-content)
    static let base        = Color.black                                    // behind video / full-screen
    static let background   = Color(red: 0.035, green: 0.037, blue: 0.055)  // app background
    static let surface      = Color(red: 0.090, green: 0.094, blue: 0.118)  // cards / sections
    static let surfaceHigh  = Color(red: 0.130, green: 0.135, blue: 0.165)  // raised elements / skeletons

    static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.07, green: 0.075, blue: 0.105),
            Color(red: 0.02, green: 0.02, blue: 0.035)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Text
    static let primary   = Color(red: 0.97, green: 0.97, blue: 0.99)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary  = Color.white.opacity(0.34)

    /// 1px hairline used to separate cards/rows instead of colored or heavy shadows.
    static let separator = Color.white.opacity(0.08)
    static let hairline  = Color.white.opacity(0.10)

    // MARK: - Glass depth
    /// A hairline that catches light at the top and fades down the edge — the premium
    /// "pane of dark glass" cue. Replaces the flat separator stroke on cards/buttons.
    static let glassEdge = LinearGradient(
        colors: [Color.white.opacity(0.24), Color.white.opacity(0.08), Color.white.opacity(0.04)],
        startPoint: .top,
        endPoint: .bottom
    )
    /// A barely-there vertical sheen laid over a card's fill for dimensionality (kept very
    /// low so surfaces still read as dark, never white).
    static let glassSheen = LinearGradient(
        colors: [Color.white.opacity(0.06), Color.clear, Color.clear],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Accent + semantic palette
    /// The single brand accent. Restraint here is the premium cue — don't tint everything.
    static let accent = Color(red: 0.30, green: 0.74, blue: 1.00)
    static let blue   = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let cyan   = Color(red: 0.39, green: 0.82, blue: 1.00)
    static let green  = Color(red: 0.20, green: 0.80, blue: 0.36)  // live
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.04)  // motion / alert
    static let red    = Color(red: 1.00, green: 0.27, blue: 0.23)  // recording
    static let purple = Color(red: 0.68, green: 0.42, blue: 1.00)
    static let teal   = Color(red: 0.22, green: 0.80, blue: 0.72)
    static let offline = Color.white.opacity(0.40)                 // neutral — never alarm-red

    // MARK: - Spacing & radius scale (consistent 4pt rhythm)
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }
    enum Radius {
        static let card: CGFloat = 20
        static let tile: CGFloat = 18
        static let chip: CGFloat = 11
    }
}

// MARK: - GlassCard

/// A content section card: subtle material fill + a clean 1px hairline (no heavy gradient
/// stroke or colored shadow — that's the cheap tell the spec calls out).
struct GlassCard<Content: View>: View {
    var material: Material = .regularMaterial
    let content: Content

    init(material: Material = .regularMaterial, @ViewBuilder content: () -> Content) {
        self.material = material
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous)
        content
            .padding(GlassTheme.Space.l)
            .background(material, in: shape)
            // Faint top sheen → the surface reads as a lit pane of glass, not a flat fill.
            .overlay { shape.fill(GlassTheme.glassSheen).allowsHitTesting(false) }
            // Top-lit hairline edge for depth (replaces the flat separator stroke).
            .overlay { shape.strokeBorder(GlassTheme.glassEdge, lineWidth: 1) }
    }
}

// MARK: - GlassBackground

/// Clean dark app background with a single restrained accent glow (no busy multi-radial
/// "gamer" wash — the spec explicitly warns against glow-heavy backgrounds).
struct GlassBackground: View {
    var body: some View {
        ZStack {
            GlassTheme.background.ignoresSafeArea()
            RadialGradient(
                colors: [GlassTheme.accent.opacity(0.10), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - PillButtonStyle

struct PillButtonStyle: ButtonStyle {
    var tint: Color = GlassTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.vertical, GlassTheme.Space.m)
            .background(tint, in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

// MARK: - GlassButtonStyle

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(GlassTheme.glassEdge, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

// MARK: - Status dot (live / recording / offline)

/// A small semantic status dot — green=live (gently pulsing), red=recording, gray=offline.
/// Consistent everywhere a camera's state is shown.
struct StatusDot: View {
    enum Mode { case live, recording, offline }
    let state: Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var color: Color {
        switch state {
        case .live: return GlassTheme.green
        case .recording: return GlassTheme.red
        case .offline: return GlassTheme.offline
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.7), radius: pulse ? 4 : 2)
            .scaleEffect(pulse ? 1.0 : 0.82)
            .onAppear {
                guard state != .offline, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Section header

/// A consistent section header: bold title with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title3, design: .default).weight(.bold))
                    .foregroundStyle(GlassTheme.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                }
            }
            Spacer(minLength: GlassTheme.Space.s)
            accessory()
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

extension SectionHeader {
    /// Unlabeled title + a trailing accessory closure, e.g. `SectionHeader("Security") { Image(...) }`.
    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init(title: title, subtitle: subtitle, accessory: accessory)
    }
}

// MARK: - Empty state

/// A calm, native empty state (SF Symbol + headline + one line) — never an error screen.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: GlassTheme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(GlassTheme.tertiary)
            Text(title)
                .font(.system(.title3).weight(.semibold))
                .foregroundStyle(GlassTheme.primary)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(GlassTheme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(GlassTheme.Space.xl)
    }
}

// MARK: - View Helpers

extension View {
    func glassBackground() -> some View {
        self.background(GlassBackground())
    }

    /// Apple-style frosted navigation bar: translucent material so content scrolls under it,
    /// with a dark scheme so titles/buttons stay legible over the dark UI.
    func glassNavBar() -> some View {
        self
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// Standard content-card chrome (radius + top-lit glass edge) for views that don't use GlassCard.
    func cardStroke(_ radius: CGFloat = GlassTheme.Radius.card) -> some View {
        self.overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(GlassTheme.glassEdge, lineWidth: 1)
        }
    }
}
