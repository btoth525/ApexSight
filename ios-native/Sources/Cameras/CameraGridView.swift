import SwiftUI

@MainActor
final class CameraGridViewModel: ObservableObject {
    @Published var cameraNames: [String] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var refreshTimer: Timer?

    func loadCameras() async {
        isLoading = true
        errorMessage = nil
        do {
            cameraNames = try await FrigateAPI.shared.fetchCameraNames()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func startRefreshTimer(interval: TimeInterval = 2.0) {
        stopRefreshTimer()
        // Timer fires on main thread; CameraCardView handles its own image refresh
        // This timer re-triggers the grid to re-render cards (bumps lastRefresh)
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

struct CameraGridView: View {
    @StateObject private var viewModel = CameraGridViewModel()
    @State private var lastRefresh = Date()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.cameraNames.isEmpty {
                ProgressView("Loading cameras…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.cameraNames.isEmpty {
                ContentUnavailableView {
                    Label("Connection Error", systemImage: "wifi.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await viewModel.loadCameras() } }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.cameraNames, id: \.self) { name in
                            NavigationLink(destination: LiveStreamView(cameraName: name)) {
                                CameraCardView(cameraName: name, lastRefresh: lastRefresh)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
                .refreshable { await viewModel.loadCameras() }
            }
        }
        .task { await viewModel.loadCameras() }
        .onReceive(timer) { date in
            lastRefresh = date
        }
    }
}

#Preview {
    NavigationStack {
        CameraGridView()
            .navigationTitle("Cameras")
    }
    .preferredColorScheme(.dark)
}
