import ActivityKit
import Foundation

/// Starts / ends the house-mode arm Live Activity, driven from AppState.requestHouseMode when you
/// arm or disarm from the app. Arming Away shows an exit-delay countdown that flips to "Armed";
/// arming Night (no exit delay) shows "Armed Night" straight away. Disarming clears it.
@MainActor
enum HouseModeActivityController {
    /// The pending auto-end Task. Held + cancelled so a stale linger from a PREVIOUS arm can't fire
    /// and tear down a freshly-armed banner (arm Away → disarm → arm Night: the Away linger must not
    /// end the Night banner mid-window).
    private static var lingerTask: Task<Void, Never>?

    /// Start the arm banner. `exitDelay` (seconds) drives the countdown — 0 = instant (Night).
    static func startArm(mode: String, by: String, exitDelay: Double) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endAllNow()   // never stack two house-mode banners

        let endsAt = exitDelay > 0 ? Date().addingTimeInterval(exitDelay).timeIntervalSince1970 : 0
        let state = HouseModeActivityAttributes.ContentState(mode: mode, by: by, endsAt: endsAt)
        // Keep it up through the countdown + ~90s of "Armed" confirmation, then let it dismiss —
        // the persistent arm status lives on the Lock Screen widget, not a long-running activity.
        let linger = (exitDelay > 0 ? exitDelay : 0) + 90
        let dismiss = Date().addingTimeInterval(linger)
        _ = try? Activity.request(
            attributes: HouseModeActivityAttributes(startedAt: Date().timeIntervalSince1970),
            content: ActivityContent(state: state, staleDate: dismiss),
            pushType: nil
        )
        lingerTask?.cancel()   // supersede any prior arm's pending auto-end
        lingerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
            if Task.isCancelled { return }
            await endAll()
        }
    }

    /// Disarm / cancel — clear any house-mode banner immediately.
    static func disarm() { endAllNow() }

    private static func endAllNow() {
        lingerTask?.cancel(); lingerTask = nil
        for activity in Activity<HouseModeActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    static func endAll() async {
        for activity in Activity<HouseModeActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
