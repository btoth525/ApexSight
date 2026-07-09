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
struct ApexArmAwayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.brandontoth.apexsight.control.armaway") {
            ControlWidgetButton(action: ApexArmAwayIntent()) {
                Label("Arm Away", systemImage: "shield.lefthalf.filled")
            }
        }
        .displayName("Arm House — Away")
        .description("Arm the whole house to Away mode.")
    }
}

@available(iOS 18.0, *)
struct ApexHouseModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.brandontoth.apexsight.control.housemode") {
            ControlWidgetButton(action: ApexHouseModeIntent()) {
                Label("House: \(SharedHouseMode.title(SharedHouseMode.mode))",
                      systemImage: SharedHouseMode.symbol(SharedHouseMode.mode))
            }
        }
        .displayName("House Mode")
        .description("Open House Mode to arm or disarm.")
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
