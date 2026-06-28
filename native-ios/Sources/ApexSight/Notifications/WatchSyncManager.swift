import Foundation
import WatchConnectivity

/// Bridges the iPhone app and the paired Apple Watch over WatchConnectivity.
/// App groups don't span devices, so the phone pushes recent alerts (+ a small
/// hero thumbnail) to the watch via `updateApplicationContext`, and handles
/// snooze/resume requests the watch sends back. A no-op when there's no watch.
final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Mirror the latest alerts (newest first) plus an optional small hero JPEG to the
    /// watch. Safe to call often — `updateApplicationContext` coalesces to the latest.
    func push(alerts: [SharedAlert], heroJPEG: Data?) {
        guard let session, session.activationState == .activated else { return }
        let encoded: [[String: Any]] = alerts.prefix(8).map { alert in
            var dict: [String: Any] = [
                "label": alert.label,
                "camera": alert.camera,
                "severity": alert.severity,
                "when": alert.when.timeIntervalSince1970
            ]
            if let sub = alert.subLabel { dict["subLabel"] = sub }
            if let id = alert.id { dict["id"] = id }
            return dict
        }
        var payload: [String: Any] = [
            "updatedAt": Date().timeIntervalSince1970,
            "alerts": encoded
        ]
        // Keep the thumbnail small — application context has a tight size budget.
        if let heroJPEG, heroJPEG.count < 180_000 { payload["heroJPEG"] = heroJPEG }
        try? session.updateApplicationContext(payload)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handle(message)
        replyHandler(["ok": true])
    }

    private func handle(_ message: [String: Any]) {
        switch message["action"] as? String {
        case "snooze":
            let minutes = message["minutes"] as? Int ?? 60
            let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
            GlobalSnooze.snooze(until: until)
            // The phone may be woken in the background just to receive this message, so the
            // 15s foreground poll that normally mirrors the gate isn't running. Push it to
            // the relay now, else app-closed pushes keep firing despite the watch snooze.
            Task { await RelayGate.sync(snoozedUntil: until.timeIntervalSince1970) }
        case "resume":
            GlobalSnooze.clear()
            Task { await RelayGate.sync(snoozedUntil: 0) }
        default:
            break
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
