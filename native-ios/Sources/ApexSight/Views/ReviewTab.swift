import SwiftUI

struct ReviewTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSeverity = "all"
    @State private var path = NavigationPath()

    private var filtered: [FrigateReviewItem] {
        appState.reviews.filter { selectedSeverity == "all" || $0.severity == selectedSeverity }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                Group {
                    if appState.reviews.isEmpty && !appState.isLoading {
                        emptyState
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                // Filter chips
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        chip("All", selected: selectedSeverity == "all") { selectedSeverity = "all" }
                                        chip("🚨 Alerts", selected: selectedSeverity == "alert") { selectedSeverity = "alert" }
                                        chip("🔍 Detections", selected: selectedSeverity == "detection") { selectedSeverity = "detection" }
                                    }
                                    .padding(.horizontal, 16)
                                }
                                .padding(.top, 8)

                                Text("\(filtered.count) items")
                                    .font(.system(size: 12, weight: .heavy))
                                    .foregroundStyle(GlassTheme.secondary)
                                    .padding(.horizontal, 16)

                                LazyVStack(spacing: 10) {
                                    ForEach(filtered) { review in
                                        Button { path.append(review) } label: {
                                            ReviewRow(review: review)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 20)
                            }
                        }
                        .refreshable { await appState.refresh() }
                    }
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if appState.isLoading { ProgressView().tint(GlassTheme.cyan) }
                }
            }
            .navigationDestination(for: FrigateReviewItem.self) { review in
                ReviewDetailView(review: review)
            }
            .task { if appState.reviews.isEmpty { await appState.refresh() } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 52, weight: .black))
                .foregroundStyle(GlassTheme.green)
            Text("All Clear")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(GlassTheme.primary)
            Text("No review items")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(selected ? Color.black : GlassTheme.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(selected ? GlassTheme.cyan : .white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
