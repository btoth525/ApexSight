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

    var isAlert: Bool { severity == "alert" }

    /// Orange for alerts, cyan for routine detections — mirrors the iOS app + CarPlay.
    var tint: Color { isAlert ? .orange : .cyan }

    /// Object glyph keyed on the detection class (not the sub-label, which may be a name).
    var glyph: String {
        switch label.lowercased() {
        case "person": return "🚶"
        case "car", "vehicle": return "🚗"
        case "truck": return "🚚"
        case "dog": return "🐕"
        case "cat": return "🐈"
        case "package": return "📦"
        case "bicycle": return "🚲"
        case "motorcycle": return "🏍️"
        case "bird": return "🐦"
        default: return isAlert ? "🚨" : "📹"
        }
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

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
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
                        heroCard(hero, latest)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                Section {
                    if store.alerts.isEmpty {
                        emptyRow
                    } else {
                        ForEach(store.alerts) { alert in
                            alertRow(alert)
                        }
                    }
                } header: {
                    Text(store.alerts.isEmpty ? "Recent" : "Recent · \(store.alerts.count)")
                }

                Section {
                    snoozeControl
                }
            }
            .navigationTitle("ApexSight")
        }
    }

    // MARK: - Hero (latest detection)

    private func heroCard(_ image: UIImage, _ latest: WatchAlert) -> some View {
        ZStack(alignment: .bottomLeading) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 116)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(latest.glyph)
                    Text(latest.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                (Text(latest.cameraName) + Text(" · ") + Text(latest.when, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Text(latest.isAlert ? "ALERT" : "SEEN")
                .font(.system(size: 9, weight: .black))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(latest.tint, in: Capsule())
                .foregroundStyle(.black)
                .padding(6)
        }
    }

    // MARK: - Rows

    private func alertRow(_ alert: WatchAlert) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(alert.tint.opacity(0.22)).frame(width: 30, height: 30)
                Text(alert.glyph).font(.system(size: 15))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.body)
                    .lineLimit(1)
                (Text(alert.cameraName) + Text(" · ") + Text(alert.when, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            Text("All clear").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var snoozeControl: some View {
        if let until = store.snoozedUntil, until > Date() {
            Label("Snoozed until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "moon.zzz.fill")
                .foregroundStyle(.secondary)
        } else {
            Button {
                store.snooze(minutes: 60)
            } label: {
                Label("Snooze 1 hour", systemImage: "moon.zzz")
            }
            .tint(.cyan)
        }
    }
}
