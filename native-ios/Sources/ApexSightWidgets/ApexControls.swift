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
                Label(ArmStateStore.notificationsActive ? "Armed" : "Disarmed",
                      systemImage: ArmStateStore.notificationsActive ? "shield.fill" : "shield.slash.fill")
            }
        }
        .displayName("Arm ApexSight")
        .description("Arm or disarm your camera alerts.")
    }
}
