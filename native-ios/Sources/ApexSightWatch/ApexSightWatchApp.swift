import SwiftUI
import WatchConnectivity
import UIKit

@main
struct ApexSightWatchApp: App {
    @StateObject private var store = WatchAlertStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
        }
    }
}

// MARK: - Model

struct WatchAlert: Identifiable {
    let id: String
    let label: String
    let subLabel: String?
    let camera: String
    let severity: String
    let when: Date

    var title: String {
        (subLabel ?? label).replacingOccurrences(of: "_", with: " ").capitalized
    }

    var cameraName: String {
        camera.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Store (receives pushes from the iPhone)

final class WatchAlertStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published var alerts: [WatchAlert] = []
    @Published var heroImage: UIImage?
    @Published var snoozedUntil: Date?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func snooze(minutes: Int) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.sendMessage(
            ["action": "snooze", "minutes": minutes],
            replyHandler: nil,
            errorHandler: { _ in }
        )
        snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    private func apply(_ context: [String: Any]) {
        DispatchQueue.main.async {
            if let raw = context["alerts"] as? [[String: Any]] {
                self.alerts = raw.compactMap { dict in
                    guard let label = dict["label"] as? String,
                          let camera = dict["camera"] as? String,
                          let when = dict["when"] as? Double else { return nil }
                    return WatchAlert(
                        id: dict["id"] as? String ?? UUID().uuidString,
                        label: label,
                        subLabel: dict["subLabel"] as? String,
                        camera: camera,
                        severity: dict["severity"] as? String ?? "alert",
                        when: Date(timeIntervalSince1970: when)
                    )
                }
            }
            if let data = context["heroJPEG"] as? Data {
                self.heroImage = UIImage(data: data)
            }
        }
    }

    // MARK: WCSessionDelegate (watchOS)

    func session(_ session: WCSession, activationDidComplete state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        if !context.isEmpty { apply(context) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }
}

// MARK: - Views

struct WatchRootView: View {
    @EnvironmentObject private var store: WatchAlertStore

    var body: some View {
        NavigationStack {
            List {
                if let hero = store.heroImage, let latest = store.alerts.first {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(uiImage: hero)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(latest.title).font(.headline)
                            Text("\(latest.cameraName) · ") + Text(latest.when, style: .relative)
                        }
                    }
                }

                Section("Recent") {
                    if store.alerts.isEmpty {
                        Text("No recent alerts")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.alerts) { alert in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.title).font(.body)
                                (Text(alert.cameraName) + Text(" · ") + Text(alert.when, style: .relative))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    if let until = store.snoozedUntil, until > Date() {
                        Label("Snoozed until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "moon.zzz.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            store.snooze(minutes: 60)
                        } label: {
                            Label("Snooze 1 hour", systemImage: "moon.zzz")
                        }
                    }
                }
            }
            .navigationTitle("ApexSight")
        }
    }
}
