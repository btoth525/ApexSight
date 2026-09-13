import AppIntents
import Foundation

// Action intents that live in the shared layer so they can be invoked from the main
// app, the widget (interactive buttons), and Control Center / Lock Screen controls.
// They touch only app-group state (GlobalSnooze) or stash a pending deep link, so
// they run correctly in any of those processes.

@available(iOS 17.0, *)
struct ApexSnoozeIntent: AppIntent {
    static let title: LocalizedStringResource = "Snooze Camera Alerts"
    static let description = IntentDescription("Mute ApexSight alerts for an hour.")
    // Silencing every camera alert from a LOCKED phone must cost a Face ID / passcode — same rule
    // as the arm toggle. (SnoozeAlertsIntent is the Shortcuts-facing twin; this one backs controls.)
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        GlobalSnooze.snooze(until: Date().addingTimeInterval(60 * 60))
        await SharedRelayGate.syncCurrent()
        return .result()
    }
}

@available(iOS 17.0, *)
struct ApexResumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Camera Alerts"
    static let description = IntentDescription("Turn ApexSight alerts back on.")
    static let isDiscoverable = false   // ResumeAlertsIntent is the Shortcuts-facing one

    func perform() async throws -> some IntentResult {
        GlobalSnooze.clear()
        await SharedRelayGate.syncCurrent()
        return .result()
    }
}


@available(iOS 17.0, *)
struct ApexOpenAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ApexSight"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult { .result() }
}

// MARK: - Arm / Disarm

@available(iOS 17.0, *)
enum ApexArmModeAppEnum: String, AppEnum {
    case disarmed, home, away, night

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Security Mode"
    static let caseDisplayRepresentations: [ApexArmModeAppEnum: DisplayRepresentation] = [
        .disarmed: "Disarmed",
        .home: "Home",
        .away: "Away",
        .night: "Night"
    ]

    var core: ArmMode { ArmMode(rawValue: rawValue) ?? .away }
}

@available(iOS 17.0, *)
struct ApexSetArmModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Security Mode"
    static let description = IntentDescription("Arm or disarm ApexSight (Home, Away, Night, or Disarmed).")
    // This can DISARM (silence every camera alert), so it must not run from a locked device — require
    // Face ID / passcode first. Otherwise "Hey Siri, disarm ApexSight" on a locked, stolen phone kills
    // all alerting with no authentication.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Mode")
    var mode: ApexArmModeAppEnum

    func perform() async throws -> some IntentResult & ProvidesDialog {
        ArmStateStore.mode = mode.core
        await SharedRelayGate.syncCurrent()
        // This intent sets the app's own NOTIFICATION gate — it does not touch Alarmo or the real
        // house mode (that is ApexArmAwayIntent / ApexHouseModeIntent). Saying "ApexSight is now
        // Away" borrowed SharedHouseMode's exact vocabulary, so a security app told the user in
        // its own voice that the house was armed when nothing had been armed. Same confusion the
        // Control Center label and the widget footer were already fixed to avoid. Dialog only —
        // the identifiers, titles and shortcut phrases are untouched so existing Shortcuts keep
        // working.
        let spoken = mode.core == .disarmed
            ? "Camera alerts are now off."
            : "Camera alerts are now on (\(mode.core.title))."
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}

/// Control Center SNOOZE toggle: on = snoozed for an hour, off = resumed. A toggle shows the
/// current state and offers the way back; the old stateless button re-snoozed silently on every tap.
@available(iOS 18.0, *)
struct ApexSnoozeToggleIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Snooze Camera Alerts"
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static let isDiscoverable = false

    @Parameter(title: "Snoozed")
    var value: Bool

    func perform() async throws -> some IntentResult {
        if value { GlobalSnooze.snooze(until: Date().addingTimeInterval(60 * 60)) } else { GlobalSnooze.clear() }
        await SharedRelayGate.syncCurrent()
        return .result()
    }
}

/// Control Center toggle backing intent: on = Away, off = Disarmed.
@available(iOS 18.0, *)
struct ApexArmToggleIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Arm ApexSight"
    // The "off" position DISARMS (silences all camera alerts), so require authentication — a locked
    // phone's Control Center must not let anyone toggle alerting off without Face ID / passcode.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Armed")
    var value: Bool

    func perform() async throws -> some IntentResult {
        ArmStateStore.mode = value ? .away : .disarmed
        await SharedRelayGate.syncCurrent()
        return .result()
    }
}

// MARK: - House Mode (Alarmo) — arm from a control/widget; open the app for the secure disarm

/// Arms the house to Away from a Control Center control / widget button / Live Activity, without
/// opening the app. Arming raises security, so it's allowed directly; disarming is never done here
/// (it needs Face ID + the Alarmo code, which live in the app — see ApexHouseModeIntent).
@available(iOS 17.0, *)
struct ApexArmAwayIntent: AppIntent {
    static let title: LocalizedStringResource = "Arm Away"
    static let description = IntentDescription("Arm the house to Away mode.")
    static let isDiscoverable = false   // no surface wires this yet; keep it out of Shortcuts

    func perform() async throws -> some IntentResult {
        await SharedRelayGate.setHouseMode("away")
        ApexSurfaceRefresh.reload()
        return .result()
    }
}

/// Opens the app to the House Mode control — used for anything needing the secure flow (disarm =
/// Face ID + Alarmo code) or the full switcher.
@available(iOS 17.0, *)
struct ApexHouseModeIntent: AppIntent {
    static let title: LocalizedStringResource = "House Mode"
    static let description = IntentDescription("Open ApexSight House Mode to arm or disarm.")
    static let openAppWhenRun = true
    static let isDiscoverable = false   // `apex://house` has no in-app route; keep it out of Shortcuts

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: ApexAppGroup.identifier)?
            .set("apex://house", forKey: "apex.pendingIntentLink")
        return .result()
    }
}

// MARK: - Focus filter — REMOVED ON PURPOSE (2026-08-15). Do not re-add.
//
// ApexSight used to publish a `SetFocusFilterIntent`, so any iOS Focus (Sleep, Do Not Disturb,
// Driving…) could switch camera alerts off. It worked exactly as designed and the design was
// wrong for this app: a Focus you set for one reason silently disabled home security for hours,
// and the only clue was a small banner you had to open the app to see.
//
// Removing the intent is what removes ApexSight from Focus Filters in iOS Settings — a Focus can
// no longer reach in and mute the cameras. iOS still decides whether to *display* a given
// notification while a Focus is on; that is the system's call, and the relay already marks
// anything above routine as time-sensitive so it breaks through.

@available(iOS 17.0, *)
struct ApexOpenCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Camera"
    static let description = IntentDescription("Open a camera's live view in ApexSight.")
    static let openAppWhenRun = true

    @Parameter(title: "Camera")
    var camera: String

    init() {}
    init(camera: String) { self.camera = camera }

    func perform() async throws -> some IntentResult {
        let name = camera.trimmingCharacters(in: .whitespaces)
        if let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            UserDefaults(suiteName: ApexAppGroup.identifier)?
                .set("apex://camera?name=\(encoded)", forKey: "apex.pendingIntentLink")
        }
        return .result()
    }
}
