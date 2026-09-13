import Combine
import Foundation

/// The one thing image views need from `AppState` — the client — on an object that only publishes
/// when the client actually changes.
///
/// `RemoteImage`, `LiveSnapshotView` and `TrackedSnapshot` used `@EnvironmentObject AppState`, and
/// `@EnvironmentObject` invalidates on ANY `objectWillChange`. During a person event AppState
/// publishes ~7 Hz of live detections plus ~4 Hz of events, so every thumbnail on Activity, Explore
/// and Review re-evaluated `body` a dozen times a second for a value that never moved. This object
/// watches AppState on their behalf, compares the client's identity, and republishes only on change.
@MainActor
final class ImageSession: ObservableObject {
    static let shared = ImageSession()

    @Published private(set) var client: FrigateClient?
    private weak var appState: AppState?
    private var subscription: AnyCancellable?

    private init() {}

    func bind(_ appState: AppState) {
        self.appState = appState
        client = appState.client
        subscription = appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] _ in
                guard let self, let appState else { return }
                let next = appState.client
                if next?.identity != self.client?.identity { self.client = next }
            }
    }

    /// Re-run login on a 401 — forwarded so image loaders keep their existing recovery path.
    func reauthenticate() async -> Bool {
        await appState?.reauthenticate() ?? false
    }
}
