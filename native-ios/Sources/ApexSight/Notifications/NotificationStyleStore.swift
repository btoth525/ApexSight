import Foundation
import SwiftUI

/// Persists the user's NotificationStyle and pushes it to the relay whenever it
/// changes, so app-closed instant pushes follow the in-app settings.
@MainActor
final class NotificationStyleStore: ObservableObject {
    @Published var style: NotificationStyle {
        didSet {
            save()
            Task { await sync() }
        }
    }

    private let key = "apex.notificationStyle"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(NotificationStyle.self, from: data) {
            style = decoded
        } else {
            style = NotificationStyle()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(style) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Pushes the current style to the relay for this device's pairing code.
    /// Safe to call often; silently no-ops if the relay is unreachable.
    func sync() async {
        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relayURL.isEmpty, !pairing.isEmpty else { return }
        try? await RelayClient.syncStyle(relayURL: relayURL, pairingCode: pairing, style: style)
    }
}
