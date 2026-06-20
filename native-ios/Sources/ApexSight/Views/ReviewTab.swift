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
    // Optimistic dismiss + Undo: hide instantly, commit to the server after a grace
    // window so a mis-tap is one tap to undo.
    @State private var hiddenIDs: Set<String> = []
    @State private var pendingReview: FrigateReviewItem?
    @State private var pendingWork: DispatchWorkItem?

    private var filtered: [FrigateReviewItem] {
        let base: [FrigateReviewItem]
        switch selectedSeverity {
        case "detection": base = detectionItems
        case "alert":     base = appState.reviews.filter { $0.severity == "alert" }
        default:          base = appState.reviews
        }
        // Exclude anything just marked viewed (e.g. from the detail screen) so it can't
        // linger — detectionItems is owned here and isn't pruned by AppState's refresh.
        let visible = base.filter { !appState.locallyViewedIDs.contains($0.id) && !hiddenIDs.contains($0.id) }
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

    /// Hide the item right away and show an Undo bar; only mark it reviewed on the
    /// server once the grace window passes — so a stray tap is recoverable.
    private func dismissReview(_ review: FrigateReviewItem) {
        Haptics.success()
        commitPending()   // a previous undo, if any, becomes final
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            hiddenIDs.insert(review.id)
            pendingReview = review
        }
        let work = DispatchWorkItem { commitPending() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    private func commitPending() {
        pendingWork?.cancel()
        pendingWork = nil
        guard let review = pendingReview else { return }
        withAnimation(.easeOut(duration: 0.2)) { pendingReview = nil }
        Task { await appState.markReviewViewed(review) }
    }

    private func undoDismiss() {
        Haptics.tap()
        pendingWork?.cancel()
        pendingWork = nil
        let review = pendingReview
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let review { hiddenIDs.remove(review.id) }
            pendingReview = nil
        }
    }

    @ViewBuilder
    private var undoToast: some View {
        if pendingReview != nil {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.green)
                Text("Marked reviewed")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                Button { undoDismiss() } label: {
                    Text("Undo")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(GlassTheme.cyan)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.14), lineWidth: 1) }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var showEmptyState: Bool {
        guard !appState.isLoading && !loadingDetections else { return false }
        // Use the same filtered/visible set the list renders (which excludes
        // just-viewed ids), so marking the last items reviewed shows "All Clear"
        // instead of a "0 items" header with no rows.
        return filtered.isEmpty
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
                            List {
                                Section {
                                    ForEach(filtered) { review in
                                        ReviewRow(
                                            review: review,
                                            onOpen: { path.append(review) },
                                            onDismiss: { dismissReview(review) }
                                        )
                                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button { dismissReview(review) } label: {
                                                Label("Reviewed", systemImage: "checkmark")
                                            }
                                            .tint(GlassTheme.green)
                                        }
                                    }
                                } header: {
                                    Text("\(filtered.count) items")
                                        .font(.system(size: 12, weight: .heavy))
                                        .foregroundStyle(GlassTheme.secondary)
                                        .textCase(nil)
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
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
            .overlay(alignment: .bottom) { undoToast }
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
                            Haptics.select()
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
        Button(action: { Haptics.select(); action() }) {
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
