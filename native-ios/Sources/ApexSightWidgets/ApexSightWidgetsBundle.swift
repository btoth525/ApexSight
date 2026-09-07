import WidgetKit
import SwiftUI

@main
struct ApexSightWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CameraSnapshotWidget()
        SelectedCameraWidget()
        if #available(iOS 18.0, *) {
            ApexSnoozeControl()
            ApexOpenControl()
            ApexArmControl()
        }
    }
}
