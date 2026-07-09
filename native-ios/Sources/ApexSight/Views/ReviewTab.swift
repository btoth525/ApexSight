import SwiftUI
import UIKit

struct ReviewTab: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var pendingWork: Task<Void, Never>?

    private var filtered: [FrigateReviewItem] {
        let base: [FrigateReviewItem]
        switch selectedSeverity {
        case "detection": base = detectionItems
        case "alert":     base = appState.reviews.filter { $0.severity == "alert" }
        default:          base = appState.reviews
        }
        // Exclude anything just marked viewed (e.g. from the detail screen) so it can't
        // linger — detectionItems is owned here and isn't pruned by AppState's refresh.
        // Also hide cameras the current house mode silences, so the feed matches the
        // notification rule (Home = Front Driveway + Doorbell). Fail-open + user-overridable.
        let visible = base.filter {
            !appState.locallyViewedIDs.contains($0.id) && !hiddenIDs.contains($0.id)
                && appState.cameraVisibleInFeeds($0.camera)
        }
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
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
            hiddenIDs.insert(review.id)
            pendingReview = review
        }
        pendingWork = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            commitPending()
        }
    }

    private func commitPending() {
        pendingWork?.cancel()
        pendingWork = nil
        guard let review = pendingReview else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { pendingReview = nil }
        Task { await appState.markReviewViewed(review) }
    }

    private func undoDismiss() {
        Haptics.tap()
        pendingWork?.cancel()
        pendingWork = nil
        let review = pendingReview
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
            if let review { hiddenIDs.remove(review.id) }
            pendingReview = nil
        }
    }

    @ViewBuilder
    private var undoToast: some View {
        if pendingReview != nil {
            HStack(spacing: GlassTheme.Space.m) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.green)
                Text("Marked reviewed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                Spacer(minLength: GlassTheme.Space.m)
                Button { undoDismiss() } label: {
                    Text("Undo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.vertical, GlassTheme.Space.m)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1) }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.bottom, GlassTheme.Space.l)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var showEmptyState: Bool {
        guard !appState.isLoading && !loadingDetections else { return false }
        // Don't mistake an unreachable server for "All Clear" — the error state owns that case.
        guard !showErrorState else { return false }
        // Use the same filtered/visible set the list renders (which excludes
        // just-viewed ids), so marking the last items reviewed shows "All Clear"
        // instead of a "0 items" header with no rows.
        return filtered.isEmpty
    }

    /// The last fetch failed (server unreachable) AND we have nothing cached to show — so the
    /// screen offers Retry instead of falsely reading as "All Clear" over a dead connection.
    private var showErrorState: Bool {
        guard !appState.isLoading && !loadingDetections else { return false }
        return !appState.isReachable && filtered.isEmpty
    }

    private func retry() async {
        Haptics.tap()
        await appState.refresh()
        if selectedSeverity == "detection" { await loadDetections() }
    }

    /// Calm error state with a retry, so a failed load is recoverable instead of a blank queue.
    private var errorState: some View {
        VStack(spacing: GlassTheme.Space.l) {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "Can't Reach Server",
                message: "We couldn't load your review items. Check your connection and try again."
            )
            Button {
                Task { await retry() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(GlassTheme.Space.l)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                VStack(spacing: 0) {
                    // Filter chips — always visible regardless of content
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: GlassTheme.Space.s) {
                            chip("All", selected: selectedSeverity == "all") { selectedSeverity = "all" }
                            chip("Alerts", selected: selectedSeverity == "alert") { selectedSeverity = "alert" }
                            chip("Detections", selected: selectedSeverity == "detection") { selectedSeverity = "detection" }
                        }
                        .padding(.horizontal, GlassTheme.Space.l)
                    }
                    .padding(.vertical, GlassTheme.Space.s)

                    FeedModeFilterBanner()
                        .padding(.horizontal, GlassTheme.Space.l)
                        .padding(.bottom, GlassTheme.Space.s)

                    Group {
                        if showErrorState {
                            errorState
                        } else if showEmptyState {
                            emptyState
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if (appState.isLoading || loadingDetections) && filtered.isEmpty {
                            ScrollView {
                                SkeletonList(rows: 7)
                                    .padding(.top, GlassTheme.Space.s)
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
                                    Text("^[\(filtered.count) item](inflect: true)")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(GlassTheme.secondary)
                                        .monospacedDigit()
                                        .textCase(nil)
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .softScrollEdges()
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
                    HStack(spacing: GlassTheme.Space.m) {
                        if appState.isLoading { ProgressView().tint(GlassTheme.accent) }
                        // Gate on the VISIBLE list, not just reviews — the Detections filter renders
                        // from `detectionItems` (which mark-all also clears), so keying off
                        // appState.reviews hid the button while detections were on screen.
                        if !filtered.isEmpty {
                            Button {
                                showMarkAllConfirm = true
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(GlassTheme.green)
                            }
                            .accessibilityLabel("Mark all reviewed")
                        }
                        Button {
                            Haptics.select()
                            sortNewest.toggle()
                        } label: {
                            Image(systemName: sortNewest ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(GlassTheme.accent)
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
            .task(id: "\(selectedSeverity)-\(scenePhase)") {
                // Re-keyed on scenePhase so backgrounding cancels the loop and foreground
                // restarts it — no 15s polling while the app is in the background.
                guard selectedSeverity == "detection", scenePhase == .active else { return }
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
            .onDisappear {
                // Leaving the tab finalizes any pending dismissal immediately so the
                // grace-period Task never outlives the view.
                if pendingReview != nil { commitPending() }
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: selectedSeverity == "detection" ? "magnifyingglass" : "checkmark.shield",
            title: selectedSeverity == "detection" ? "No Detections" : "All Clear",
            message: selectedSeverity == "detection"
                ? "No detection events for this filter."
                : "You're all caught up — no review items."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.select(); action() }) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .white : GlassTheme.primary)
                .padding(.horizontal, GlassTheme.Space.m)
                .padding(.vertical, GlassTheme.Space.s)
                .background {
                    Capsule().fill(selected ? GlassTheme.accent : GlassTheme.surface)
                }
                .overlay {
                    if !selected { Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
