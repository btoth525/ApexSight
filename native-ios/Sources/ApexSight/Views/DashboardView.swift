import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedCamera = "all"
    @State private var selectedLabel = "all"
    @State private var selectedReviewSeverity = "all"
    @State private var path = NavigationPath()

    private var labels: [String] {
        Array(Set(appState.labels + appState.events.map(\.label))).sorted()
    }

    private var filteredEvents: [FrigateEvent] {
        appState.events.filter { event in
            (selectedCamera == "all" || event.camera == selectedCamera) &&
            (selectedLabel == "all" || event.label == selectedLabel)
        }
    }

    private var filteredReviews: [FrigateReviewItem] {
        appState.reviews.filter { review in
            selectedReviewSeverity == "all" || review.severity == selectedReviewSeverity
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    commandStatusStrip

                    if let error = appState.errorMessage {
                        GlassCard {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(GlassTheme.orange)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionTitle("Live Cameras", subtitle: "\(appState.cameras.count) online")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                                ForEach(appState.cameras) { camera in
                                    CameraCard(camera: camera)
                                }
                            }
                        }
                    }

                    if !appState.reviews.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 14) {
                                sectionTitle("Review Alerts", subtitle: "\(filteredReviews.count) Frigate review items")
                                reviewFilterChips
                                VStack(spacing: 10) {
                                    ForEach(filteredReviews.prefix(8)) { review in
                                        Button {
                                            path.append(review)
                                        } label: {
                                            ReviewRow(review: review)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionTitle("Recent Activity", subtitle: "\(filteredEvents.count) matching alerts")
                            filterChips
                            eventRows
                        }
                    }

                    if !appState.capabilities.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 14) {
                                sectionTitle("Camera Capabilities", subtitle: "Snapshots, recordings, PTZ, WebRTC")
                                VStack(spacing: 10) {
                                    ForEach(appState.capabilities) { capability in
                                        CapabilityRow(capability: capability)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .refreshable {
                await appState.refresh()
            }
            .task {
                if appState.cameras.isEmpty && appState.events.isEmpty {
                    await appState.refresh()
                }
            }
            } // ZStack
            .onChange(of: appState.deepLink) { _, route in
                guard let route else { return }
                handleDeepLink(route)
                appState.deepLink = nil
            }
            .navigationDestination(for: FrigateEvent.self) { event in
                EventDetailView(event: event)
            }
            .navigationDestination(for: FrigateReviewItem.self) { review in
                ReviewDetailView(review: review)
            }
            .navigationDestination(for: String.self) { value in
                if value == "system" {
                    SystemHealthView()
                } else if value == "notifications" {
                    NotificationSettingsView()
                } else if value == "servers" {
                    ServerSwitcherView()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apex Command")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(GlassTheme.primary)
                Text(appState.session?.baseURL.host() ?? "Frigate security overview")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(GlassTheme.secondary)
            }
            Spacer()
            Button {
                path.append("notifications")
            } label: {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 18, weight: .heavy))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .foregroundStyle(GlassTheme.orange)

            Button {
                path.append("system")
            } label: {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 18, weight: .heavy))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .foregroundStyle(GlassTheme.green)

            Button {
                path.append("servers")
            } label: {
                Image(systemName: "server.rack")
                    .font(.system(size: 18, weight: .heavy))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .foregroundStyle(GlassTheme.primary)

            Button {
                appState.signOut()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 18, weight: .heavy))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .foregroundStyle(GlassTheme.primary)
        }
    }

    private var commandStatusStrip: some View {
        GlassCard {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    commandMetric(
                        icon: "video.fill",
                        title: "Live",
                        value: "\(appState.cameras.count)",
                        tint: GlassTheme.blue
                    )
                    commandMetric(
                        icon: "bell.badge.fill",
                        title: "Review",
                        value: "\(appState.reviews.count)",
                        tint: GlassTheme.orange
                    )
                    commandMetric(
                        icon: "tag.fill",
                        title: "Labels",
                        value: "\(appState.labels.count)",
                        tint: GlassTheme.cyan
                    )
                    commandMetric(
                        icon: "waveform.path.ecg",
                        title: "Health",
                        value: appState.errorMessage == nil ? "Good" : "Check",
                        tint: appState.errorMessage == nil ? GlassTheme.green : GlassTheme.red
                    )
                    commandMetric(
                        icon: "lock.shield.fill",
                        title: "Mode",
                        value: "Local",
                        tint: GlassTheme.cyan
                    )
                }
            }
        }
    }

    private func commandMetric(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(GlassTheme.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
            }
        }
        .frame(minWidth: 116, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var filterChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All Cameras", selected: selectedCamera == "all") { selectedCamera = "all" }
                    ForEach(appState.cameras) { camera in
                        chip(titleize(camera.name), selected: selectedCamera == camera.name) {
                            selectedCamera = camera.name
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All Objects", selected: selectedLabel == "all") { selectedLabel = "all" }
                    ForEach(labels, id: \.self) { label in
                        chip(titleize(label), selected: selectedLabel == label) {
                            selectedLabel = label
                        }
                    }
                }
            }
        }
    }

    private var reviewFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: selectedReviewSeverity == "all") {
                    selectedReviewSeverity = "all"
                }
                chip("Alerts", selected: selectedReviewSeverity == "alert") {
                    selectedReviewSeverity = "alert"
                }
                chip("Detections", selected: selectedReviewSeverity == "detection") {
                    selectedReviewSeverity = "detection"
                }
            }
        }
    }

    private var eventRows: some View {
        VStack(spacing: 10) {
            if filteredEvents.isEmpty {
                Text("No matching events.")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GlassTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(filteredEvents) { event in
                Button {
                    path.append(event)
                } label: {
                    EventRow(event: event)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(GlassTheme.secondary)
            }
            Spacer()
            if appState.isLoading {
                ProgressView()
                    .tint(GlassTheme.cyan)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(selected ? Color.black : GlassTheme.primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(selected ? GlassTheme.cyan : .white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func handleDeepLink(_ route: AppDeepLink) {
        switch route {
        case .review(let id):
            if let review = appState.reviews.first(where: { $0.id == id }) {
                path.append(review)
            }
        case .event(let id):
            if let event = appState.events.first(where: { $0.id == id }) {
                path.append(event)
            } else {
                Task {
                    guard let event = try? await appState.client?.event(id: id) else { return }
                    path.append(event)
                }
            }
        case .camera(let name):
            selectedCamera = name
        }
    }
}

func titleize(_ value: String) -> String {
    value
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}
