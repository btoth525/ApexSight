import WidgetKit
import SwiftUI
import AppIntents

// Control Center / Lock Screen / Action Button controls (iOS 18+).

@available(iOS 18.0, *)
struct ApexSnoozeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.brandontoth.apexsight.control.snooze") {
            ControlWidgetButton(action: ApexSnoozeIntent()) {
                Label("Snooze Alerts", systemImage: "moon.zzz.fill")
            }
        }
        .displayName("Snooze ApexSight")
        .description("Mute camera alerts for an hour.")
    }
}

@available(iOS 18.0, *)
struct ApexOpenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.brandontoth.apexsight.control.open") {
            ControlWidgetButton(action: ApexOpenAppIntent()) {
                Label("ApexSight", systemImage: "video.fill")
            }
        }
        .displayName("Open ApexSight")
        .description("Jump straight to your cameras.")
    }
}

@available(iOS 18.0, *)
struct ApexArmControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.brandontoth.apexsight.control.arm") {
            ControlWidgetToggle(
                isOn: ArmStateStore.notificationsActive,
                action: ApexArmToggleIntent()
            ) {
                // Says "Alerts", not "Armed". This toggle is the app's NOTIFICATION gate — it does
                // not arm or disarm the house (that's House Mode / Alarmo, the control above).
                // Labelling it "Armed" let a muted-alerts state read as a secured house, which is
                // the most dangerous way for a security app to be ambiguous.
                Label(ArmStateStore.notificationsActive ? "Alerts on" : "Alerts off",
                      systemImage: ArmStateStore.notificationsActive ? "bell.fill" : "bell.slash.fill")
            }
        }
        .displayName("ApexSight Alerts")
        .description("Turn camera alerts on or off. Does not arm the house — use House Mode for that.")
    }
}
