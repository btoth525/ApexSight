import SwiftUI

struct ReviewRow: View {
    let review: FrigateReviewItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: review.severity == "alert" ? "bell.badge.fill" : "scope")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(review.severity == "alert" ? GlassTheme.orange : GlassTheme.cyan)
                .frame(width: 42, height: 42)
                .background((review.severity == "alert" ? GlassTheme.orange : GlassTheme.cyan).opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(NotificationCopy.title(for: review))
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                    .lineLimit(1)

                Text(NotificationCopy.body(for: review))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GlassTheme.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let count = review.data?.detections?.count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(GlassTheme.cyan, in: Capsule())
            }
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
