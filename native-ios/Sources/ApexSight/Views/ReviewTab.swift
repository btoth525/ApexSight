import SwiftUI
import UIKit

struct ReviewTab: View {
    @EnvironmentObject private var appState: AppState
    // Persisted so the filter/sort choice survives navigating away and back.
    @AppStorage("review.selectedSeverity") private var selectedSeverity = "all"
    @AppStorage("review.sortNewest") private var sortNewest = true
    @State private var path = NavigationPath()
    /// Detection-severity reviews are fetched on demand — Frigate's default review list
    /// is dominated by alerts, so a dedicated `severity=detection` query is needed.
    @State private var detectionItems: [FrigateReviewItem] = []
    @State private var loadingDetections = false
    @State private var showMarkAllConfirm = false

    private var filtered: [FrigateReviewItem] {
        let base: [FrigateReviewItem]
        switch selectedSeverity {
        case "detection": base = detectionItems
        case "alert":     base = appState.reviews.filter { $0.severity == "alert" }
        default:          base = appState.reviews
        }
        // Exclude anything just marked viewed (e.g. from the detail screen) so it can't
        // linger — detectionItems is owned here and isn't pruned by AppState's refresh.
        let visible = base.filter { !appState.locallyViewedIDs.contains($0.id) }
        return sortNewest
            ? visible.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
            : visible.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
    }

    private func loadDetections(silent: Bool = false) async {
        guard let client = appState.client else { return }
        if !silent { loadingDetections = true }
        detectionItems = ((try? await client.reviews(limit: 100, severity: "detection", reviewed: false)) ?? [])
            .filter { !($0.hasBeenReviewed ?? false) && !appState.locallyViewedIDs.contains($0.id) }
        if !silent { loadingDetections = false }
    }

    private var showEmptyState: Bool {
        guard !appState.isLoading && !loadingDetections else { return false }
        switch selectedSeverity {
        case "detection": return detectionItems.isEmpty
        case "alert": return appState.reviews.filter { $0.severity == "alert" }.isEmpty
        default: return appState.reviews.isEmpty
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                VStack(spacing: 0) {
                    // Filter chips — always visible regardless of content
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All", selected: selectedSeverity == "all") { selectedSeverity = "all" }
                            chip("🚨 Alerts", selected: selectedSeverity == "alert") { selectedSeverity = "alert" }
                            chip("🔍 Detections", selected: selectedSeverity == "detection") { selectedSeverity = "detection" }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 8)
                    .background(GlassTheme.background)

                    Group {
                        if showEmptyState {
                            emptyState
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if (appState.isLoading || loadingDetections) && filtered.isEmpty {
                            ScrollView {
                                SkeletonList(rows: 7)
                                    .padding(.top, 8)
                            }
                            .disabled(true)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("\(filtered.count) items")
                                        .font(.system(size: 12, weight: .heavy))
                                        .foregroundStyle(GlassTheme.secondary)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 4)

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
                            .refreshable {
                                await appState.refresh()
                                if selectedSeverity == "detection" { await loadDetections() }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if appState.isLoading { ProgressView().tint(GlassTheme.cyan) }
                        if !appState.reviews.isEmpty {
                            Button {
                                showMarkAllConfirm = true
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18, weight: .black))
                                    .foregroundStyle(GlassTheme.green)
                            }
                            .accessibilityLabel("Mark all reviewed")
                        }
                        Button {
                            sortNewest.toggle()
                        } label: {
                            Image(systemName: sortNewest ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(GlassTheme.cyan)
                        }
                        .accessibilityLabel(sortNewest ? "Sorted newest first" : "Sorted oldest first")
                        .accessibilityHint("Toggles sort order")
                    }
                }
            }
            .confirmationDialog(
                // Marks the entire server backlog, not just the items loaded here, so
                // the copy doesn't promise a misleading visible-count.
                "Mark every review item as reviewed?",
                isPresented: $showMarkAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Mark All Reviewed") {
                    Task {
                        await appState.markAllReviewsViewed()
                        detectionItems = []
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(for: FrigateReviewItem.self) { review in
                ReviewDetailView(review: review)
            }
            .navigationDestination(for: FrigateEvent.self) { event in
                EventDetailView(event: event)
            }
            .task { if appState.reviews.isEmpty { await appState.refresh() } }
            .task(id: selectedSeverity) {
                guard selectedSeverity == "detection" else { return }
                if detectionItems.isEmpty { await loadDetections() }
                // Keep detections live while this filter is active (the 15s poller only
                // refreshes alerts); the task is cancelled when the filter changes or the
                // tab goes away.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if Task.isCancelled { break }
                    await loadDetections(silent: true)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedSeverity == "detection" ? "magnifyingglass" : "checkmark.shield.fill")
                .font(.system(size: 52, weight: .black))
                .foregroundStyle(selectedSeverity == "detection" ? GlassTheme.cyan : GlassTheme.green)
            Text(selectedSeverity == "detection" ? "No Detections" : "All Clear")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(GlassTheme.primary)
            Text(selectedSeverity == "detection" ? "No detection events for this filter." : "No review items")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GlassTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
