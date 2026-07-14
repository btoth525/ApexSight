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
        // transferUserInfo (not sendMessage): queued + delivered in the background even when the
        // iPhone app isn't running, so the snooze reliably reaches the phone (and the relay)
        // instead of silently failing when the phone is unreachable while we optimistically show
        // "Snoozed".
        WCSession.default.transferUserInfo(["action": "snooze", "minutes": minutes])
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
            // Set unconditionally (nil when this update carries no hero) — the phone omits heroJPEG
            // when the thumbnail download fails/oversizes, and leaving the OLD image up would pair the
            // previous alert's photo with the new alert's caption.
            self.heroImage = (context["heroJPEG"] as? Data).flatMap { UIImage(data: $0) }
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
                        NavigationLink {
                            WatchAlertDetailView(alert: latest, image: hero)
                        } label: {
                            heroCard(hero, latest)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }

                Section {
                    if store.alerts.isEmpty {
                        emptyRow
                    } else {
                        ForEach(store.alerts) { alert in
                            NavigationLink {
                                WatchAlertDetailView(
                                    alert: alert,
                                    image: alert.id == store.alerts.first?.id ? store.heroImage : nil
                                )
                            } label: {
                                alertRow(alert)
                            }
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

// MARK: - Alert detail

struct WatchAlertDetailView: View {
    let alert: WatchAlert
    let image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(alert.tint.opacity(0.18))
                            .frame(height: 96)
                        Text(alert.glyph).font(.system(size: 44))
                    }
                }

                HStack(spacing: 6) {
                    Text(alert.glyph)
                    Text(alert.title).font(.headline).lineLimit(2)
                }

                Text(alert.isAlert ? "ALERT" : "Detection")
                    .font(.system(size: 10, weight: .black))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(alert.tint, in: Capsule())
                    .foregroundStyle(.black)

                Label(alert.cameraName, systemImage: "video.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(alert.when.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .navigationTitle(alert.cameraName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
