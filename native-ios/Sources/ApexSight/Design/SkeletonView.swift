import SwiftUI

/// A shimmering placeholder block, used while content loads so a screen shows its
/// shape immediately instead of a lone centered spinner.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = 12
    @State private var shimmer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                GeometryReader { geo in
                    let width = geo.size.width
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 0.6)
                    .offset(x: shimmer ? width : -width * 0.6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                // Reduce Motion: keep the static placeholder, skip the looping sweep.
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    shimmer = true
                }
            }
    }
}

/// A stack of row-shaped skeletons (thumbnail + two text lines) that mimics a
/// loading list. Hidden from VoiceOver since it conveys no real content.
struct SkeletonList: View {
    var rows: Int = 6

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonBlock(cornerRadius: 14)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock()
                            .frame(height: 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SkeletonBlock()
                            .frame(width: 140, height: 12)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
    }
}
