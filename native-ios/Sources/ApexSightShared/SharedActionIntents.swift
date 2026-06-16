import AppIntents
import Foundation

// Action intents that live in the shared layer so they can be invoked from the main
// app, the widget (interactive buttons), and Control Center / Lock Screen controls.
// They touch only app-group state (GlobalSnooze) or stash a pending deep link, so
// they run correctly in any of those processes.

@available(iOS 17.0, *)
struct ApexSnoozeIntent: AppIntent {
    static var title: LocalizedStringResource = "Snooze Camera Alerts"
    static var description = IntentDescription("Mute ApexSight alerts for an hour.")

    func perform() async throws -> some IntentResult {
        GlobalSnooze.snooze(until: Date().addingTimeInterval(60 * 60))
        return .result()
    }
}

@available(iOS 17.0, *)
struct ApexResumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Camera Alerts"
    static var description = IntentDescription("Turn ApexSight alerts back on.")

    func perform() async throws -> some IntentResult {
        GlobalSnooze.clear()
        return .result()
    }
}

@available(iOS 17.0, *)
struct ApexOpenAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Open ApexSight"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult { .result() }
}

@available(iOS 17.0, *)
struct ApexOpenCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Camera"
    static var description = IntentDescription("Open a camera's live view in ApexSight.")
    static var openAppWhenRun = true

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
