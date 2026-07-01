import WidgetKit
import SwiftUI

@main
struct ApexSightWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CameraSnapshotWidget()
        SelectedCameraWidget()
        // The incident Live Activity self-selects the `.small` supplemental family on iOS 18+
        // (CarPlay Dashboard + Watch Smart Stack); no bundle branching needed.
        IncidentLiveActivity()
        if #available(iOS 18.0, *) {
            ApexSnoozeControl()
            ApexOpenControl()
            ApexArmControl()
        }
    }
}
